// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Gemini Live's native-audio output rate (`audio/pcm;rate=24000`). The web
/// player uses the same (src/lib/audio/pcm-player.ts OUTPUT_SAMPLE_RATE).
const int geminiOutputSampleRate = 24000;

abstract interface class PcmAudioBackend {
  Future<void> setAudioStream(Stream<List<int>> stream);

  Future<void> play();

  Future<void> stop();

  Future<void> dispose();
}

class JustAudioPcmBackend implements PcmAudioBackend {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> setAudioStream(Stream<List<int>> stream) async {
    await _player.setAudioSource(_PcmStreamAudioSource(stream));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// Streams agent PCM to the speaker and keeps a playback clock.
///
/// Gemini delivers audio faster than real time, so "a chunk just arrived"
/// says nothing about whether Lumen is still audible. Like the web player's
/// scheduled tail, every accepted chunk extends an estimated end-of-playback
/// instant by its own duration; [speaking] is true until that instant passes.
class PcmPlayer {
  PcmPlayer({PcmAudioBackend? backend, Duration Function()? now})
      : _backend = backend ?? JustAudioPcmBackend(),
        _now = now ?? _monotonic();

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final PcmAudioBackend _backend;
  final Duration Function() _now;
  final ValueNotifier<bool> _speaking = ValueNotifier(false);
  Duration _tail = Duration.zero;
  Timer? _silenceTimer;

  /// True while fed audio is still (estimated to be) playing.
  ValueListenable<bool> get speaking => _speaking;

  /// Estimated audio still queued ahead of the listener.
  Duration get remaining {
    final left = _tail - _now();
    return left.isNegative ? Duration.zero : left;
  }
  StreamController<List<int>>? _controller;
  Future<void> _lifecycleTail = Future<void>.value();
  bool _initialized = false;
  bool _acceptingAudio = false;
  bool _disposed = false;
  int _generation = 0;

  Future<void> init() {
    return _serialized(() async {
      if (_disposed || _initialized) return;
      await _startSource(_generation);
    });
  }

  /// Queues audio for playback and advances the playback clock. This is not
  /// a playback acknowledgement. With [audible] false (muted) the audio skips
  /// the speaker but still counts as time Lumen is talking, so the UI keeps
  /// showing who has the floor.
  bool feed(
    Uint8List pcm16, {
    int sampleRate = geminiOutputSampleRate,
    bool audible = true,
  }) {
    final controller = _controller;
    if (!_acceptingAudio ||
        controller == null ||
        controller.isClosed ||
        _disposed) {
      return false;
    }
    if (audible) {
      controller.add(prependWavHeader(pcm16, sampleRate: sampleRate));
    }
    _advanceClock(pcm16.length, sampleRate);
    return true;
  }

  void _advanceClock(int bytes, int sampleRate) {
    if (bytes <= 0 || sampleRate <= 0) return;
    final now = _now();
    final start = _tail > now ? _tail : now;
    // PCM16 mono: two bytes per sample.
    _tail = start +
        Duration(microseconds: (bytes / 2 / sampleRate * 1e6).round());
    _speaking.value = true;
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_tail - now, _onSilenceDue);
  }

  void _onSilenceDue() {
    _silenceTimer = null;
    final left = _tail - _now();
    if (left > Duration.zero) {
      // Timers can fire a hair early; re-arm for the remainder.
      _silenceTimer = Timer(left, _onSilenceDue);
      return;
    }
    _speaking.value = false;
  }

  void _resetClock() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _tail = _now();
    if (!_disposedNotifier) _speaking.value = false;
  }

  bool _disposedNotifier = false;

  /// Stops the current source, discards everything buffered in it, and starts
  /// a fresh playback generation. Audio arriving while the reset is in
  /// progress is deliberately dropped rather than leaking across an
  /// interruption.
  Future<void> flush() {
    _generation += 1;
    _acceptingAudio = false;
    _resetClock();
    return _serialized(() async {
      if (_disposed) return;
      final generation = _generation;
      await _backend.stop();
      await _closeController();
      _initialized = false;
      await _startSource(generation);
    });
  }

  Future<void> dispose() {
    _generation += 1;
    _acceptingAudio = false;
    _disposed = true;
    _resetClock();
    _disposedNotifier = true;
    _speaking.dispose();
    return _serialized(() async {
      await _backend.stop();
      await _closeController();
      _initialized = false;
      await _backend.dispose();
    });
  }

  Future<void> _startSource(int generation) async {
    final controller = StreamController<List<int>>.broadcast();
    _controller = controller;
    await _backend.setAudioStream(controller.stream);
    if (_disposed || generation != _generation) {
      if (identical(_controller, controller)) _controller = null;
      await controller.close();
      return;
    }
    await _backend.play();
    if (_disposed || generation != _generation) return;
    _initialized = true;
    _acceptingAudio = true;
  }

  Future<void> _closeController() async {
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  Future<void> _serialized(Future<void> Function() operation) {
    final result = _lifecycleTail.then((_) => operation());
    _lifecycleTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}

/// Wraps one PCM16 mono chunk as a WAV. [sampleRate] must be the rate the
/// audio was produced at — Gemini's output is 24kHz; labelling it 16kHz (as
/// this did originally) plays Lumen at 2/3 speed and a fifth lower.
Uint8List prependWavHeader(
  Uint8List pcm16, {
  int sampleRate = geminiOutputSampleRate,
}) {
  const channels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  const blockAlign = channels * bitsPerSample ~/ 8;
  final dataLength = pcm16.length;
  final totalLength = dataLength + 36;
  final bytes = BytesBuilder(copy: false);
  final header = ByteData(44);

  void setAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  setAscii(0, 'RIFF');
  header.setUint32(4, totalLength, Endian.little);
  setAscii(8, 'WAVE');
  setAscii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  setAscii(36, 'data');
  header.setUint32(40, dataLength, Endian.little);

  bytes.add(header.buffer.asUint8List());
  bytes.add(pcm16);
  return bytes.takeBytes();
}

class _PcmStreamAudioSource extends StreamAudioSource {
  final Stream<List<int>> _stream;

  _PcmStreamAudioSource(this._stream) : super(tag: 'pcm-live');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: null,
      stream: _stream,
      contentType: 'audio/wav',
    );
  }
}

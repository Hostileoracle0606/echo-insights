import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logic/voice_log.dart';
import 'voice_engine.dart';

/// Gemini Live's native-audio output rate (`audio/pcm;rate=24000`). The web
/// player uses the same (src/lib/audio/pcm-player.ts OUTPUT_SAMPLE_RATE).
const int geminiOutputSampleRate = 24000;

/// Where scheduled PCM goes. The app plays through the native voice engine;
/// tests use a fake.
abstract interface class PcmAudioBackend {
  /// Readies the speaker. Must never wait for audio to arrive.
  Future<void> start();

  /// Queues one PCM16 mono chunk behind everything already queued.
  Future<void> schedule(Uint8List pcm16, int sampleRate);

  /// Drops everything queued; the backend stays ready.
  Future<void> stop();

  Future<void> dispose();
}

/// Lumen's voice through the shared engine, so the mic's echo canceller
/// hears it.
class VoiceEnginePlayback implements PcmAudioBackend {
  VoiceEnginePlayback(this._engine);
  final VoiceEngine _engine;

  @override
  Future<void> start() => _engine.prepare();

  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) =>
      _engine.schedule(pcm16, sampleRate);

  @override
  Future<void> stop() => _engine.stopPlayback();

  // The engine is app-wide; a disposed player only silences what it queued.
  @override
  Future<void> dispose() => _engine.stopPlayback();
}

/// Plays agent PCM and keeps a playback clock.
///
/// Gemini delivers audio faster than real time, so "a chunk just arrived"
/// says nothing about whether Lumen is still audible. Like the web player's
/// scheduled tail, every accepted chunk extends an estimated end-of-playback
/// instant by its own duration; [speaking] is true until that instant passes.
///
/// It used to stream WAV-wrapped chunks into just_audio, whose
/// `setAudioSource` waited for audio that could only arrive after `init` —
/// so on a device `init` always timed out and Lumen was never heard.
/// Samples are now queued on the native engine, which is ready at once.
class PcmPlayer {
  PcmPlayer({PcmAudioBackend? backend, Duration Function()? now})
      : _backend = backend ?? VoiceEnginePlayback(VoiceEngine.instance),
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
  bool _ready = false;
  bool _disposed = false;
  bool _disposedNotifier = false;
  Future<void>? _disposing;

  /// True while fed audio is still (estimated to be) playing.
  ValueListenable<bool> get speaking => _speaking;

  /// Estimated audio still queued ahead of the listener.
  Duration get remaining {
    final left = _tail - _now();
    return left.isNegative ? Duration.zero : left;
  }

  bool get isDisposed => _disposed;

  Future<void> init() async {
    if (_disposed || _ready) return;
    await _backend.start();
    if (!_disposed) _ready = true;
  }

  /// Queues audio and advances the playback clock. This is not a playback
  /// acknowledgement. With [audible] false (muted) the audio skips the
  /// speaker but still counts as time Lumen is talking, so the UI keeps
  /// showing who has the floor.
  bool feed(
    Uint8List pcm16, {
    int sampleRate = geminiOutputSampleRate,
    bool audible = true,
  }) {
    if (!_ready || _disposed) return false;
    if (audible) {
      _backend.schedule(pcm16, sampleRate).catchError((Object error) {
        vlog('playback', 'schedule failed: $error');
      });
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

  /// Stops what's queued (a barge-in); the player stays ready.
  Future<void> flush() async {
    _resetClock();
    if (_disposed) return;
    await _backend.stop();
  }

  /// Idempotent: a session teardown and a failed init may both dispose.
  Future<void> dispose() {
    return _disposing ??= () async {
      _disposed = true;
      _ready = false;
      _resetClock();
      _disposedNotifier = true;
      _speaking.dispose();
      await _backend.dispose();
    }();
  }
}

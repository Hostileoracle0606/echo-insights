// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

class PcmPlayer {
  final AudioPlayer _player = AudioPlayer();
  final _controller = StreamController<List<int>>.broadcast();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final source = _PcmStreamAudioSource(_controller.stream);
    await _player.setAudioSource(source);
    await _player.play();
  }

  void feed(Uint8List pcm16) {
    if (!_initialized || _controller.isClosed) return;
    _controller.add(prependWavHeader(pcm16));
  }

  Future<void> dispose() async {
    await _controller.close();
    await _player.dispose();
  }
}

Uint8List prependWavHeader(Uint8List pcm16) {
  const sampleRate = 16000;
  const channels = 1;
  const bitsPerSample = 16;
  const byteRate = sampleRate * channels * bitsPerSample ~/ 8;
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

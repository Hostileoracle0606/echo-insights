import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../logic/voice_log.dart';

class PcmCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  int _chunks = 0;

  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    vlog('capture', 'starting stream (pcm16, 16kHz, mono)');
    _chunks = 0;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _sub = stream.listen((pcm) {
      _chunks++;
      if (_chunks == 1 || _chunks % 100 == 0) {
        vlog('capture', 'mic chunk #$_chunks (${pcm.length} B)');
      }
      onChunk(pcm);
    });
  }

  Future<void> stop() async {
    vlog('capture', 'stopping (delivered $_chunks chunks)');
    await _sub?.cancel();
    await _recorder.stop();
  }

  Future<bool> hasPermission() async => _recorder.hasPermission();
}

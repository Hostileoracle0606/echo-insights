import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

class PcmCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _sub = stream.listen(onChunk);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _recorder.stop();
  }

  Future<bool> hasPermission() async => _recorder.hasPermission();
}

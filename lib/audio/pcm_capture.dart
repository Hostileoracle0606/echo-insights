import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../logic/voice_log.dart';

/// The microphone as a session sees it; tests substitute a fake.
abstract interface class MicCapture {
  Future<bool> hasPermission();

  Future<void> start(void Function(Uint8List pcm16) onChunk);

  Future<void> stop();
}

class PcmCapture implements MicCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  int _chunks = 0;

  /// 16 kHz PCM16 mono, as Gemini Live expects. Echo cancellation keeps
  /// Lumen's own voice from the speaker out of the mic (on iOS it switches
  /// on voice processing); gain control and noise suppression steady the
  /// user's level. Each is applied only where the platform supports it.
  static const config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
    autoGain: true,
    echoCancel: true,
    noiseSuppress: true,
  );

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    vlog('capture', 'starting stream (pcm16, 16kHz, mono, voice processing)');
    _chunks = 0;
    final stream = await _recorder.startStream(config);
    _sub = stream.listen((pcm) {
      _chunks++;
      if (_chunks == 1 || _chunks % 100 == 0) {
        vlog('capture', 'mic chunk #$_chunks (${pcm.length} B)');
      }
      onChunk(pcm);
    });
  }

  @override
  Future<void> stop() async {
    vlog('capture', 'stopping (delivered $_chunks chunks)');
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
  }

  @override
  Future<bool> hasPermission() async => _recorder.hasPermission();
}

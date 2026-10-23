import 'dart:async';

import 'package:flutter/services.dart';

import '../logic/voice_log.dart';
import 'voice_engine.dart';

/// The microphone as a session sees it; tests substitute a fake.
abstract interface class MicCapture {
  Future<bool> hasPermission();

  Future<void> start(void Function(Uint8List pcm16) onChunk);

  Future<void> stop();
}

/// The mic through the shared voice engine: 16 kHz PCM16 mono with Apple's
/// voice processing, whose echo canceller hears Lumen because Lumen plays
/// through the same engine. (The `record` plugin ran voice processing on an
/// engine of its own, which could never hear Lumen's voice.)
class EngineMicCapture implements MicCapture {
  EngineMicCapture([VoiceEngine? engine])
      : _engine = engine ?? VoiceEngine.instance;

  final VoiceEngine _engine;
  StreamSubscription<Uint8List>? _sub;
  int _chunks = 0;

  @override
  Future<bool> hasPermission() async =>
      await _engine.hasMicPermission() || await _engine.requestMicPermission();

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    vlog('capture',
        'starting (16 kHz PCM16 mono, voice processing, shared engine)');
    await _sub?.cancel();
    _chunks = 0;
    _sub = _engine.micChunks().listen(
      (pcm) {
        _chunks++;
        if (_chunks == 1 || _chunks % 100 == 0) {
          vlog('capture', 'mic chunk #$_chunks (${pcm.length} B)');
        }
        onChunk(pcm);
      },
      onError: (Object error) => vlog('capture', 'mic stream error: $error'),
    );
  }

  @override
  Future<void> stop() async {
    vlog('capture', 'stopping (delivered $_chunks chunks)');
    await _sub?.cancel();
    _sub = null;
  }
}

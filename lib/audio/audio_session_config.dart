import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// Configures the shared iOS audio session for simultaneous playback AND
/// recording before any audio component starts. Without this, just_audio
/// sets a playback-only category and the record plugin (which doesn't
/// manage the session by default) taps a mic the session can't record
/// from — the classic "dock listens, hears nothing" failure on device.
/// Safe to call repeatedly; failures are logged, never thrown.
Future<void> configureVoiceAudioSession() async {
  try {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
    ));
  } catch (error) {
    debugPrint('[audio] audio session config unavailable: $error');
  }
}

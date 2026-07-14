// ON-DEVICE mic-capture probe. Runs on a simulator or physical iPhone and
// replicates startSession's exact audio order (audio-session config → playback
// init → mic capture), then measures what the mic actually delivers:
//
//   flutter test integration_test/mic_capture_probe_test.dart -d <device-id>
//
// Reports chunk count, effective byte-rate (≈32,000 B/s means true 16kHz mono
// int16), and peak amplitude (0 = pure silence). This is the layer no Mac-side
// probe can exercise — the backend audio path is already proven by
// test/gemini_live_audio_probe.dart.
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lumen/audio/pcm_capture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mic capture streams real PCM under the app audio config',
      (tester) async {
    // 1. Same session config the app now applies in startSession.
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
    ));
    debugPrintSynchronously('[probe] audio session configured (playAndRecord)');

    // 2. Mic capture, playback deliberately absent: startSession now starts
    // capture BEFORE playback (playback is optional and its init can stall on
    // the simulator, blocking other audio plugin calls), so pure capture under
    // the playAndRecord session is exactly the app's critical path.
    debugPrintSynchronously('[probe] checking mic permission…');
    final capture = PcmCapture();
    final permitted =
        await capture.hasPermission().timeout(const Duration(seconds: 15));
    debugPrintSynchronously('[probe] mic permission: $permitted');
    expect(permitted, isTrue, reason: 'microphone permission not granted');

    var chunks = 0;
    var bytes = 0;
    var peak = 0;
    final sw = Stopwatch()..start();
    await capture.start((Uint8List pcm) {
      chunks++;
      bytes += pcm.length;
      // Chunks can be unaligned views (odd offsetInBytes), so read samples
      // via ByteData rather than asInt16List (which requires 2-byte alignment).
      final bd = ByteData.sublistView(pcm);
      for (var i = 0; i + 1 < pcm.length; i += 2) {
        final a = bd.getInt16(i, Endian.little).abs();
        if (a > peak) peak = a;
      }
    });

    // Capture ~2.5 seconds of real time.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2500)));
    sw.stop();
    await capture.stop();

    final seconds = sw.elapsedMilliseconds / 1000.0;
    final rate = bytes / seconds;
    debugPrintSynchronously(
        '[probe] RESULT: chunks=$chunks bytes=$bytes over '
        '${seconds.toStringAsFixed(1)}s → ${rate.toStringAsFixed(0)} B/s '
        '(expect ≈32000 for 16kHz mono int16), peakAmplitude=$peak/32767');

    expect(chunks, greaterThan(0),
        reason: 'no audio chunks — the capture stream never produced data');
    // 16kHz mono int16 = 32,000 B/s. Allow generous tolerance, but a hardware
    // rate leaking through (≈88,200/96,000 B/s) or a trickle must fail.
    expect(rate, greaterThan(20000),
        reason: 'byte-rate far below 16kHz mono int16 — capture is starved');
    expect(rate, lessThan(48000),
        reason: 'byte-rate far above 16kHz mono int16 — resample to 16k is '
            'not happening; Gemini would hear garbage');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

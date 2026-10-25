import 'package:flutter/foundation.dart';

/// Milliseconds since the app first logged, so `flutter run` output can be
/// turned into durations (scripts/latency/voice-timing-report.mjs).
final Stopwatch _clock = Stopwatch()..start();

/// Uniform voice-pipeline logging: one place controls the format so `flutter
/// run` output can be filtered with a single prefix. Debug builds only.
///
///   flutter run … | grep '\[voice\]'
///
/// Each line carries a monotonic `@<ms>` stamp:
///
///   [voice][client] @12345 gemini → turnComplete
///
/// [area] is the subsystem ('client', 'session', 'capture', 'playback').
void vlog(String area, String message) {
  if (kDebugMode) {
    debugPrint('[voice][$area] @${_clock.elapsedMilliseconds} $message');
  }
}

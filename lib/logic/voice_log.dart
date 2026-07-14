import 'package:flutter/foundation.dart';

/// Uniform voice-pipeline logging: one place controls the format so `flutter
/// run` output can be filtered with a single prefix. Debug builds only.
///
///   flutter run … | grep '\[voice\]'
///
/// [area] is the subsystem ('client', 'session', 'capture', 'playback').
void vlog(String area, String message) {
  if (kDebugMode) debugPrint('[voice][$area] $message');
}

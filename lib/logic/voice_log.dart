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

/// Journal-provider diagnostics, keeping their `[journal]` prefix. Debug
/// builds only: unlike asserts, `debugPrint` is not stripped from release
/// builds, and these carry backend error text.
void jlog(String message) {
  if (kDebugMode) debugPrint('[journal] $message');
}

/// Stack traces for the same diagnostics. Debug builds only, for the same
/// reason: `debugPrintStack` also survives release builds.
void vlogStack(StackTrace? stackTrace) {
  if (kDebugMode) debugPrintStack(stackTrace: stackTrace);
}

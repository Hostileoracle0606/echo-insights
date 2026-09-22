import 'package:supabase_flutter/supabase_flutter.dart';

/// User-facing text for a failed auth call. [AuthException] messages are
/// written for end users; anything else (SDK assertions, socket errors) is
/// replaced with [fallback] so internals never reach the screen.
String authErrorMessage(Object error, {required String fallback}) {
  if (error is AuthException) return error.message;
  return fallback;
}

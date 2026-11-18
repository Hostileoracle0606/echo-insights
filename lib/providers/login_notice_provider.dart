import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';

/// Shown on login after the account was deleted (LM-116).
const deletedNotice = 'Your account is deleted.';

/// Shown instead when Apple's tokens could not be revoked: the person removes
/// Lumen from their Apple ID themselves.
const deletedAppleNotRevokedNotice =
    'Your account is deleted. Apple may still list Lumen as using Sign in '
    'with Apple. To remove it, open Settings, tap your name (Apple ID), then '
    'Sign in with Apple, choose Lumen and stop using it.';

/// A one-line message for the login screen, left by a flow that signs the
/// person out (account deletion). Cleared when someone signs in again, so it
/// never shows after a later, ordinary sign-out.
final loginNoticeProvider =
    NotifierProvider<LoginNotice, String?>(LoginNotice.new);

class LoginNotice extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(authProvider, (_, next) {
      if (next.valueOrNull != null) state = null;
    });
    return null;
  }

  void show(String message) => state = message;
}

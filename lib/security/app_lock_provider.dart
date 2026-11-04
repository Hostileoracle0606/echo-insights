import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lock.dart';

final lockAuthenticatorProvider =
    Provider<LockAuthenticator>((ref) => LocalAuthAuthenticator());

final privacyPreferenceStoreProvider =
    Provider<PrivacyPreferenceStore>((ref) => KeychainPreferenceStore());

/// The one lock for the app. Loads the saved switch on first read.
final appLockProvider = ChangeNotifierProvider<AppLockController>((ref) {
  final controller = AppLockController(
    authenticator: ref.watch(lockAuthenticatorProvider),
    store: ref.watch(privacyPreferenceStoreProvider),
  );
  controller.load();
  return controller;
});

/// Asks for Face ID (or the passcode) again before something sensitive:
/// export, deleting an account, turning the lock off, and later key
/// recovery. True when the person passed, or when they have no lock to ask
/// with (they never opted in). Callers do the sensitive thing only on true.
Future<bool> requireReauth(
  BuildContext context, {
  required String reason,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return container.read(appLockProvider).requireReauth(reason);
}

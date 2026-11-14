import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lock.dart';
import 'privacy_cover.dart';

/// The clock the lock measures time in the background with.
final lockClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final privacyCoverProvider =
    Provider<PrivacyCoverChannel>((ref) => PrivacyCoverChannel());

/// Waits for the frame just requested to be built and presented, plus one
/// more for the raster to catch up.
final lockFrameWaitProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
  };
});

final lockAuthenticatorProvider =
    Provider<LockAuthenticator>((ref) => LocalAuthAuthenticator());

final privacyPreferenceStoreProvider =
    Provider<PrivacyPreferenceStore>((ref) => KeychainPreferenceStore());

/// The one lock for the app. Loads the saved switch on first read.
final appLockProvider = ChangeNotifierProvider<AppLockController>((ref) {
  final controller = AppLockController(
    authenticator: ref.watch(lockAuthenticatorProvider),
    store: ref.watch(privacyPreferenceStoreProvider),
    now: ref.watch(lockClockProvider),
    cover: ref.watch(privacyCoverProvider),
    waitForFrame: ref.watch(lockFrameWaitProvider),
  );
  controller.load();
  return controller;
});

/// Asks for Face ID (or the passcode) again before something sensitive:
/// export, deleting an account, turning the lock off, and later key
/// recovery. Asks whether or not the app lock is on. True when the person
/// passed, or when the device has no passcode or biometrics to ask with.
/// Callers do the sensitive thing only on true.
Future<bool> requireReauth(
  BuildContext context, {
  required String reason,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return container.read(appLockProvider).requireReauth(reason);
}

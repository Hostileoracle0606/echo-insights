import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/pseudonym_store.dart';
import 'app_lock.dart';

/// Whether this is the first launch since the app was installed (R31).
///
/// The iOS Keychain outlives the app: deleting Lumen leaves its items behind,
/// and a reinstall can read them again. UserDefaults is deleted with the app,
/// so a flag kept there tells a fresh install from a relaunch.
abstract interface class InstallFlag {
  /// True when no earlier launch of this install set the flag.
  Future<bool> isFirstLaunch();
  Future<void> markLaunched();
}

/// UserDefaults on iOS (ios/Runner/AppDelegate.swift, `InstallState`).
class NativeInstallFlag implements InstallFlag {
  NativeInstallFlag([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('lumen/install');

  final MethodChannel _channel;

  /// No native side (tests, other platforms) means not a first launch: there
  /// is no Keychain to clean there either.
  @override
  Future<bool> isFirstLaunch() async {
    try {
      return await _channel.invokeMethod<bool>('isFirstLaunch') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> markLaunched() async {
    try {
      await _channel.invokeMethod<void>('markLaunched');
    } catch (_) {}
  }
}

/// The Lumen Keychain items that hold real names or privacy choices: the
/// name map, the forgotten-name hashes, the forget marker and the app-lock
/// and quiet-mode switches.
const lumenKeychainKeys = <String>[
  KeychainPseudonymStore.mapKey,
  KeychainPseudonymStore.forgottenKey,
  'privacy.forget_marker',
  lockEnabledKey,
  quietModeKey,
];

/// On the first launch after an install, deletes every item in
/// [lumenKeychainKeys] (a reinstall must not inherit the last install's real
/// names), then sets the flag. If a delete fails the flag is not set, so the
/// next launch tries again. True when the wipe ran. Never throws.
Future<bool> wipeKeychainOnFreshInstall({
  required InstallFlag flag,
  required Future<void> Function(String key) delete,
  List<String> keys = lumenKeychainKeys,
}) async {
  try {
    if (!await flag.isFirstLaunch()) return false;
    for (final key in keys) {
      await delete(key);
    }
    await flag.markLaunched();
    return true;
  } catch (_) {
    return false;
  }
}

/// The real Keychain delete (the item is found by key, whichever
/// accessibility class wrote it).
Future<void> deleteKeychainItem(String key) =>
    const FlutterSecureStorage().delete(key: key);

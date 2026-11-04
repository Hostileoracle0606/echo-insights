import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// How long the app may sit in the background before it locks again. Coming
/// back sooner (a quick look at a text) needs no Face ID; coming back at or
/// after this does.
const Duration kAppLockGracePeriod = Duration(minutes: 5);

enum AppLockStatus {
  /// The saved preference isn't read yet: covered, so nothing flashes.
  loading,

  /// The lock is off, or the user has passed it.
  unlocked,

  /// The lock screen covers the app.
  locked,
}

/// Asks the person to prove it's them: Face ID, falling back to the device
/// passcode.
abstract interface class LockAuthenticator {
  /// Whether this device has a passcode or biometrics to check against.
  Future<bool> isAvailable();

  /// True only when the person passed. A cancel or a failure is false.
  Future<bool> authenticate(String reason);
}

class LocalAuthAuthenticator implements LockAuthenticator {
  LocalAuthAuthenticator([LocalAuthentication? auth])
      : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      // biometricOnly false: Face ID, then the passcode if it fails or isn't
      // enrolled.
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
    } catch (_) {
      // Locked out, no passcode, cancelled by the system: not proven. Never
      // log the error text; it is not journal content, but there is nothing
      // useful to add.
      return false;
    }
  }
}

/// The lock and quiet-mode switches. Held in the iOS Keychain, not in a file
/// or preferences the app's sandbox exposes: editing the app's files can't
/// turn the lock off.
abstract interface class PrivacyPreferenceStore {
  /// Null when nothing was ever saved under [key]. Throws when the Keychain
  /// can't be read, which is not the same as "off".
  Future<bool?> read(String key);
  Future<void> write(String key, bool value);
}

class KeychainPreferenceStore implements PrivacyPreferenceStore {
  KeychainPreferenceStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                // Readable only while the phone is unlocked, and not carried
                // to another device by a backup.
                accessibility: KeychainAccessibility.unlocked_this_device,
              ),
            );
  final FlutterSecureStorage _storage;

  @override
  Future<bool?> read(String key) async {
    final value = await _storage.read(key: key);
    return value == null ? null : value == 'true';
  }

  @override
  Future<void> write(String key, bool value) =>
      _storage.write(key: key, value: value ? 'true' : 'false');
}

const String lockEnabledKey = 'privacy.app_lock_enabled';
const String quietModeKey = 'privacy.quiet_mode';

/// The lock state machine.
///
///   launch: loading → locked (lock on) | unlocked (lock off)
///   switch unreadable (Keychain error): locked, until a retry reads it
///   leaving the foreground (inactive, hidden, paused): [shielded], so the
///     last frame the OS keeps on screen is blank, never journal text
///   backgrounded under [kAppLockGracePeriod]: shield lifts on return
///   backgrounded at or over it: locked when the app returns
///   [unlock] passes → unlocked; fails or is cancelled → stays locked
///
/// The system's Face ID sheet makes the app inactive and resume; lifecycle
/// changes while [unlock] runs are ignored so it can't re-lock itself.
class AppLockController extends ChangeNotifier {
  AppLockController({
    required LockAuthenticator authenticator,
    required PrivacyPreferenceStore store,
    DateTime Function()? now,
    Duration gracePeriod = kAppLockGracePeriod,
  })  : _authenticator = authenticator,
        _store = store,
        _now = now ?? DateTime.now,
        _grace = gracePeriod;

  final LockAuthenticator _authenticator;
  final PrivacyPreferenceStore _store;
  final DateTime Function() _now;
  final Duration _grace;

  AppLockStatus _status = AppLockStatus.loading;
  bool _enabled = false;
  bool _authenticating = false;
  bool _loadFailed = false;
  bool _shielded = false;
  DateTime? _backgroundedAt;

  AppLockStatus get status => _status;

  /// The person turned the lock on.
  bool get enabled => _enabled;

  /// The Face ID sheet is up.
  bool get authenticating => _authenticating;

  /// The saved switch couldn't be read, so the lock can't say it is off. The
  /// app stays locked; [unlock] tries the read again.
  bool get loadFailed => _loadFailed;

  /// The app has left (or is leaving) the foreground with the lock on: cover
  /// the content now so the frame iOS keeps for the switcher and for the
  /// moment of return is blank.
  bool get shielded => _shielded;

  /// Reads the saved switch. Call at launch; again to retry after a failure.
  /// Only a key that was never written means "off".
  Future<void> load() async {
    try {
      _enabled = await _store.read(lockEnabledKey) ?? false;
      _loadFailed = false;
      _status = _enabled ? AppLockStatus.locked : AppLockStatus.unlocked;
    } catch (_) {
      _loadFailed = true;
      _enabled = true;
      _status = AppLockStatus.locked;
    }
    notifyListeners();
  }

  void lifecycleChanged(AppLifecycleState lifecycle) {
    if (!_enabled || _authenticating) return;
    switch (lifecycle) {
      case AppLifecycleState.inactive:
        // Raised before the OS captures anything; covers the switcher too.
        _setShield(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // The first of paused/hidden marks when the app left.
        _backgroundedAt ??= _now();
        _setShield(true);
      case AppLifecycleState.resumed:
        final left = _backgroundedAt;
        _backgroundedAt = null;
        if (left != null &&
            _status == AppLockStatus.unlocked &&
            _now().difference(left) >= _grace) {
          _status = AppLockStatus.locked;
        }
        // Decided above, so the content never shows before the lock does.
        _shielded = false;
        notifyListeners();
      case AppLifecycleState.detached:
        break;
    }
  }

  void _setShield(bool on) {
    if (_shielded == on) return;
    _shielded = on;
    notifyListeners();
  }

  /// Shows Face ID / passcode to lift the lock screen.
  Future<bool> unlock({
    String reason = 'Unlock your journal',
  }) async {
    if (_status == AppLockStatus.unlocked) return true;
    if (_authenticating) return false;
    if (_loadFailed) {
      await load();
      if (_loadFailed) return false;
      if (_status == AppLockStatus.unlocked) return true;
    }
    final passed = await _prove(reason);
    if (passed) {
      _status = AppLockStatus.unlocked;
      _backgroundedAt = null;
      notifyListeners();
    }
    return passed;
  }

  /// Turns the lock on, only once this device can check it (a passcode is
  /// set) and the person has passed once, so they can't lock themselves out
  /// of a lock that never worked.
  Future<bool> enable() async {
    if (_enabled) return true;
    if (!await _authenticator.isAvailable()) return false;
    if (!await _prove('Turn on app lock')) return false;
    await _store.write(lockEnabledKey, true);
    _enabled = true;
    _status = AppLockStatus.unlocked;
    notifyListeners();
    return true;
  }

  /// Turns the lock off after asking again.
  Future<bool> disable() async {
    if (!_enabled) return true;
    if (!await _prove('Turn off app lock')) return false;
    await _store.write(lockEnabledKey, false);
    _enabled = false;
    _backgroundedAt = null;
    notifyListeners();
    return true;
  }

  /// Asks again before something sensitive (export, deleting, turning the
  /// lock off), whether or not the app lock is on. It passes without asking
  /// only on a device with no passcode or biometrics to ask with.
  Future<bool> requireReauth(String reason) async {
    if (!await _authenticator.isAvailable()) return true;
    return _prove(reason);
  }

  Future<bool> _prove(String reason) async {
    if (_authenticating) return false;
    _authenticating = true;
    notifyListeners();
    try {
      return await _authenticator.authenticate(reason);
    } finally {
      _authenticating = false;
      // Returning from the Face ID sheet is not a trip to the background.
      _backgroundedAt = null;
      notifyListeners();
    }
  }
}

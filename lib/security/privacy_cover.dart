import 'package:flutter/services.dart';

/// Dart side of the native privacy cover (ios/Runner/AppDelegate.swift,
/// `PrivacyCover`): the blur laid over the window whenever the app stops being
/// active. With the app lock on, the native side keeps it up on return until
/// Dart says the lock screen (or the content) is on screen, so a stale frame
/// of journal text can never show.
class PrivacyCoverChannel {
  PrivacyCoverChannel([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('lumen/privacy');

  final MethodChannel _channel;

  /// Whether the cover waits for [releaseCover] on return. The native side
  /// assumes true until told otherwise.
  Future<void> setLockEnabled(bool enabled) => _call('setLockEnabled', enabled);

  /// What should be on screen now is; the cover can go.
  Future<void> releaseCover() => _call('releaseCover');

  Future<void> _call(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } catch (_) {
      // No native side (tests, other platforms). It times out on its own.
    }
  }
}

import 'package:flutter/services.dart';

/// iOS data-protection classes the app sets on files it writes.
enum FileProtectionLevel {
  /// Unreadable while the phone is locked. For everything that is only ever
  /// touched with the app open: exports, cached audio.
  complete('complete'),

  /// A file created while unlocked stays writable after the phone locks, and
  /// new files can still be created. For the turn journal: the last turn of a
  /// session can finish writing in the seconds after the screen locks, and a
  /// failed write there would lose it.
  completeUnlessOpen('completeUnlessOpen');

  const FileProtectionLevel(this.wire);
  final String wire;
}

typedef FileProtector = Future<void> Function(
  String path,
  FileProtectionLevel level,
);

const _channel = MethodChannel('lumen/file_protection');

/// Sets [level] on [path] (the native side is ios/Runner/AppDelegate.swift).
/// Best effort: off iOS, or where the file system can't take a class, the
/// file keeps the app-wide default (`Runner.entitlements`).
Future<void> protectFile(
  String path, [
  FileProtectionLevel level = FileProtectionLevel.complete,
]) async {
  try {
    await _channel
        .invokeMethod<void>('set', {'path': path, 'level': level.wire});
  } catch (_) {
    // No iOS runner (tests, a pure-Dart isolate) or a file system that can't
    // take a class. Never fail a save over it.
  }
}

/// The class iOS reports for [path] (`NSFileProtectionComplete`, ...), or
/// null where unknown. For verification.
Future<String?> fileProtectionOf(String path) async {
  try {
    return await _channel.invokeMethod<String>('get', {'path': path});
  } catch (_) {
    return null;
  }
}

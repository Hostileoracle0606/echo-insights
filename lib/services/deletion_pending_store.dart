import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef PendingAccountDeletion = ({
  String userId,
  String requestId,
  bool isApple,
});

/// The Keychain marker binds a retry to the account that requested it.
/// It survives until the phone's cleanup completes.
abstract interface class DeletionPendingStore {
  Future<PendingAccountDeletion?> read();
  Future<void> write(PendingAccountDeletion request);
  Future<void> clear();
}

/// The marker in the iOS Keychain, beside the other small privacy flags.
/// Not carried to another device by a backup, and wiped on a fresh install
/// (it is in `lumenKeychainKeys`), so a reinstall never resends it.
class KeychainDeletionPendingStore implements DeletionPendingStore {
  KeychainDeletionPendingStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                // Readable from launch once the phone was unlocked once.
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  static const key = 'account.deletion_pending';

  @override
  Future<PendingAccountDeletion?> read() async {
    final value = await _storage.read(key: key);
    if (value == null) return null;
    try {
      return switch (jsonDecode(value)) {
        {
          'userId': final String userId,
          'requestId': final String requestId,
          'isApple': final bool isApple,
        }
            when userId.isNotEmpty && requestId.isNotEmpty =>
          (userId: userId, requestId: requestId, isApple: isApple),
        _ => null,
      };
    } on FormatException {
      // A marker without an account cannot be safely replayed.
      return null;
    }
  }

  @override
  Future<void> write(PendingAccountDeletion request) => _storage.write(
        key: key,
        value: jsonEncode({
          'userId': request.userId,
          'requestId': request.requestId,
          'isApple': request.isApple,
        }),
      );

  @override
  Future<void> clear() => _storage.delete(key: key);
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The "deletion pending" marker: the request id of an account deletion the
/// server has not yet confirmed as queued. Written before the call to
/// `delete-account`, cleared once the server answers "queued", so a lost
/// reply is resent (with the same id) on the next try or launch. Holds the
/// request id only: no user id, token or code.
abstract interface class DeletionPendingStore {
  /// The pending request id, or null when none. Throws when the storage
  /// can't be read.
  Future<String?> read();
  Future<void> write(String requestId);
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
  Future<String?> read() async {
    final value = await _storage.read(key: key);
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> write(String requestId) =>
      _storage.write(key: key, value: requestId);

  @override
  Future<void> clear() => _storage.delete(key: key);
}

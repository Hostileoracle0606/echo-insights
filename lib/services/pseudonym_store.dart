import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the name map is kept on the device. The map holds real names, so
/// the only implementation that ships is the Keychain.
abstract interface class PseudonymStore {
  /// The saved map JSON, or null when none was saved. Throws when the
  /// storage can't be read.
  Future<String?> read();
  Future<void> write(String json);
  Future<void> delete();
}

/// The map in the iOS Keychain (encrypted by the OS, protected by the device
/// passcode), never in a file or preference the sandbox exposes, never sent
/// to the server, and not carried to another device by a backup.
class KeychainPseudonymStore implements PseudonymStore {
  KeychainPseudonymStore([FlutterSecureStorage? storage, this.key = mapKey])
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );
  final FlutterSecureStorage _storage;

  /// The Keychain item this store reads and writes.
  final String key;

  static const mapKey = 'privacy.pseudonym_map';

  /// LM-63: the keyed hashes of forgotten names, beside the map.
  static const forgottenKey = 'privacy.forgotten_names';

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String json) => _storage.write(key: key, value: json);

  @override
  Future<void> delete() => _storage.delete(key: key);
}

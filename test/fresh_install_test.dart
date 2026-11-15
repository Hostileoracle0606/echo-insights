// R31: a reinstall must not inherit the last install's Keychain items.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/security/fresh_install.dart';

class _Flag implements InstallFlag {
  _Flag({this.first = true});
  bool first;
  int marked = 0;

  @override
  Future<bool> isFirstLaunch() async => first;

  @override
  Future<void> markLaunched() async {
    marked += 1;
    first = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the first launch deletes every Lumen item, then sets the flag',
      () async {
    final flag = _Flag();
    final deleted = <String>[];
    final ran = await wipeKeychainOnFreshInstall(
      flag: flag,
      delete: (key) async => deleted.add(key),
    );
    expect(ran, isTrue);
    expect(deleted, [
      'privacy.pseudonym_map',
      'privacy.forgotten_names',
      'privacy.forget_marker',
      'privacy.app_lock_enabled',
      'privacy.quiet_mode',
    ]);
    expect(flag.marked, 1);
  });

  test('a relaunch of the same install deletes nothing', () async {
    final flag = _Flag(first: false);
    final deleted = <String>[];
    final ran = await wipeKeychainOnFreshInstall(
      flag: flag,
      delete: (key) async => deleted.add(key),
    );
    expect(ran, isFalse);
    expect(deleted, isEmpty);
    expect(flag.marked, 0);
  });

  test('running it twice wipes once', () async {
    final flag = _Flag();
    var deletes = 0;
    Future<void> delete(String _) async => deletes += 1;
    await wipeKeychainOnFreshInstall(flag: flag, delete: delete);
    final after = deletes;
    await wipeKeychainOnFreshInstall(flag: flag, delete: delete);
    expect(deletes, after);
  });

  test('a delete that fails leaves the flag unset, so the next launch retries',
      () async {
    final flag = _Flag();
    final ran = await wipeKeychainOnFreshInstall(
      flag: flag,
      delete: (key) async {
        if (key == 'privacy.forgotten_names') throw StateError('keychain');
      },
    );
    expect(ran, isFalse);
    expect(flag.marked, 0);
    expect(flag.first, isTrue);
  });

  test('a failing flag never throws', () async {
    final ran = await wipeKeychainOnFreshInstall(
      flag: _ThrowingFlag(),
      delete: (_) async {},
    );
    expect(ran, isFalse);
  });

  test('the key list covers the map, the hashes, the marker and the lock prefs',
      () {
    expect(lumenKeychainKeys, containsAll([
      'privacy.pseudonym_map',
      'privacy.forgotten_names',
      'privacy.forget_marker',
      'privacy.app_lock_enabled',
      'privacy.quiet_mode',
    ]));
  });

  group('the native flag', () {
    const channel = MethodChannel('lumen/install');

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('asks the native side and marks it', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'isFirstLaunch' ? true : null;
      });
      final flag = NativeInstallFlag();
      expect(await flag.isFirstLaunch(), isTrue);
      await flag.markLaunched();
      expect(calls, ['isFirstLaunch', 'markLaunched']);
    });

    test('with no native side it is not a first launch', () async {
      expect(await NativeInstallFlag().isFirstLaunch(), isFalse);
    });
  });
}

class _ThrowingFlag implements InstallFlag {
  @override
  Future<bool> isFirstLaunch() async => throw StateError('x');
  @override
  Future<void> markLaunched() async => throw StateError('x');
}

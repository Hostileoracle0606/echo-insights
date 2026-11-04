// The lock state machine and its gate: locked at launch, grace period in the
// background, Face ID success and failure, re-auth before sensitive actions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_gate.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/theme/lumen_theme.dart';

class FakeAuthenticator implements LockAuthenticator {
  bool available = true;
  bool passes = true;
  final reasons = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    reasons.add(reason);
    return passes;
  }
}

class MemoryStore implements PrivacyPreferenceStore {
  MemoryStore([Map<String, bool>? initial]) : values = {...?initial};
  final Map<String, bool> values;

  @override
  Future<bool> read(String key) async => values[key] ?? false;

  @override
  Future<void> write(String key, bool value) async => values[key] = value;
}

void main() {
  late FakeAuthenticator auth;
  late MemoryStore store;
  late DateTime clock;

  AppLockController build({bool enabled = true}) {
    auth = FakeAuthenticator();
    store = MemoryStore({lockEnabledKey: enabled});
    clock = DateTime(2026, 11, 4, 9);
    return AppLockController(
      authenticator: auth,
      store: store,
      now: () => clock,
    );
  }

  Future<AppLockController> launched({bool enabled = true}) async {
    final lock = build(enabled: enabled);
    await lock.load();
    return lock;
  }

  void background(AppLockController lock, Duration away) {
    lock.lifecycleChanged(AppLifecycleState.inactive);
    lock.lifecycleChanged(AppLifecycleState.hidden);
    lock.lifecycleChanged(AppLifecycleState.paused);
    clock = clock.add(away);
    lock.lifecycleChanged(AppLifecycleState.inactive);
    lock.lifecycleChanged(AppLifecycleState.resumed);
  }

  group('state machine', () {
    test('is loading, then locked at launch when the lock is on', () async {
      final lock = build();
      expect(lock.status, AppLockStatus.loading);
      await lock.load();
      expect(lock.status, AppLockStatus.locked);
    });

    test('is unlocked at launch when the lock is off', () async {
      final lock = await launched(enabled: false);
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('a passing unlock opens it', () async {
      final lock = await launched();
      expect(await lock.unlock(), isTrue);
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('a failed or cancelled unlock stays locked', () async {
      final lock = await launched();
      auth.passes = false;
      expect(await lock.unlock(), isFalse);
      expect(lock.status, AppLockStatus.locked);
      auth.passes = true;
      expect(await lock.unlock(), isTrue);
    });

    test('back within 5 minutes stays unlocked', () async {
      final lock = await launched();
      await lock.unlock();
      background(lock, kAppLockGracePeriod - const Duration(seconds: 1));
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('back after 5 minutes locks', () async {
      final lock = await launched();
      await lock.unlock();
      background(lock, kAppLockGracePeriod);
      expect(lock.status, AppLockStatus.locked);
    });

    test('the grace period is five minutes', () {
      expect(kAppLockGracePeriod, const Duration(minutes: 5));
    });

    test('the Face ID sheet (inactive, resumed) does not lock', () async {
      final lock = await launched();
      await lock.unlock();
      clock = clock.add(const Duration(hours: 1));
      lock.lifecycleChanged(AppLifecycleState.inactive);
      lock.lifecycleChanged(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('a long time in the background does nothing with the lock off',
        () async {
      final lock = await launched(enabled: false);
      background(lock, const Duration(hours: 3));
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('lifecycle changes during the Face ID prompt are ignored', () async {
      final lock = await launched();
      await lock.unlock();
      background(lock, const Duration(minutes: 1));
      // A prompt for re-auth is up while the app flickers to the background.
      final pending = lock.requireReauth('Export your notebook');
      background(lock, kAppLockGracePeriod * 2);
      await pending;
      expect(lock.status, AppLockStatus.unlocked);
    });
  });

  group('turning the lock on and off', () {
    test('on: asks once, then saves the switch', () async {
      final lock = await launched(enabled: false);
      expect(await lock.enable(), isTrue);
      expect(lock.enabled, isTrue);
      expect(store.values[lockEnabledKey], isTrue);
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('on: refused without a passcode or biometrics', () async {
      final lock = await launched(enabled: false);
      auth.available = false;
      expect(await lock.enable(), isFalse);
      expect(lock.enabled, isFalse);
      expect(store.values[lockEnabledKey], isFalse);
    });

    test('on: a failed check leaves it off', () async {
      final lock = await launched(enabled: false);
      auth.passes = false;
      expect(await lock.enable(), isFalse);
      expect(lock.enabled, isFalse);
    });

    test('off: needs Face ID again', () async {
      final lock = await launched();
      await lock.unlock();
      auth.reasons.clear();
      expect(await lock.disable(), isTrue);
      expect(auth.reasons, ['Turn off app lock']);
      expect(store.values[lockEnabledKey], isFalse);
    });

    test('off: a failed check keeps the lock on', () async {
      final lock = await launched();
      await lock.unlock();
      auth.passes = false;
      expect(await lock.disable(), isFalse);
      expect(lock.enabled, isTrue);
      expect(store.values[lockEnabledKey], isTrue);
    });
  });

  group('requireReauth', () {
    test('asks, with the given reason, and passes on success', () async {
      final lock = await launched();
      await lock.unlock();
      auth.reasons.clear();
      expect(await lock.requireReauth('Export your notebook'), isTrue);
      expect(auth.reasons, ['Export your notebook']);
    });

    test('fails when Face ID fails', () async {
      final lock = await launched();
      await lock.unlock();
      auth.passes = false;
      expect(await lock.requireReauth('Export your notebook'), isFalse);
    });

    test('passes without asking when the lock is off', () async {
      final lock = await launched(enabled: false);
      expect(await lock.requireReauth('Export your notebook'), isTrue);
      expect(auth.reasons, isEmpty);
    });
  });

  group('gate', () {
    Future<(ProviderContainer, AppLockController)> pump(
      WidgetTester tester, {
      bool enabled = true,
      bool passes = false,
    }) async {
      final lock = build(enabled: enabled);
      auth.passes = passes;
      final container = ProviderContainer(overrides: [
        lockAuthenticatorProvider.overrideWithValue(auth),
        privacyPreferenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: const AppLockGate(child: Scaffold(body: Text('journal text'))),
        ),
      ));
      await tester.pumpAndSettle();
      return (container, lock);
    }

    testWidgets('covers the app at launch and prompts once', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
      expect(find.text('journal text'), findsNothing);
      expect(auth.reasons, ['Unlock your journal']);
    });

    testWidgets('shows the app, and no lock screen, once it passes',
        (tester) async {
      await pump(tester, passes: true);
      expect(find.byKey(const Key('lockScreen')), findsNothing);
      expect(find.text('journal text'), findsOneWidget);
    });

    testWidgets('stays covered after a failed prompt; Unlock retries',
        (tester) async {
      await pump(tester);
      expect(auth.reasons, hasLength(1));
      auth.passes = true;
      await tester.tap(find.byKey(const Key('unlockButton')));
      await tester.pumpAndSettle();
      expect(auth.reasons, hasLength(2));
      expect(find.byKey(const Key('lockScreen')), findsNothing);
      expect(find.text('journal text'), findsOneWidget);
    });

    testWidgets('no lock screen when the lock is off', (tester) async {
      await pump(tester, enabled: false);
      expect(find.byKey(const Key('lockScreen')), findsNothing);
      expect(find.text('journal text'), findsOneWidget);
      expect(auth.reasons, isEmpty);
    });

    testWidgets('requireReauth(context) asks and reports the answer',
        (tester) async {
      final (container, _) = await pump(tester, passes: true);
      late BuildContext context;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(builder: (c) {
            context = c;
            return const SizedBox();
          }),
        ),
      ));
      auth.reasons.clear();
      expect(await requireReauth(context, reason: 'Export'), isTrue);
      auth.passes = false;
      expect(await requireReauth(context, reason: 'Export'), isFalse);
      expect(auth.reasons, ['Export', 'Export']);
    });
  });
}

// The lock state machine and its gate: locked at launch, grace period in the
// background, Face ID success and failure, re-auth before sensitive actions.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_gate.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/security/privacy_cover.dart';
import 'package:lumen/theme/lumen_theme.dart';

class FakeAuthenticator implements LockAuthenticator {
  bool available = true;
  bool passes = true;
  final reasons = <String>[];

  /// While set, authenticate waits on it (a Face ID sheet that is still up).
  Completer<bool>? hold;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    reasons.add(reason);
    return hold?.future ?? passes;
  }
}

/// Records what the lock tells the native cover.
class FakeCover extends PrivacyCoverChannel {
  final calls = <String>[];

  /// Runs at the moment releaseCover is called (to look at the screen then).
  void Function()? onRelease;

  @override
  Future<void> setLockEnabled(bool enabled) async =>
      calls.add('setLockEnabled($enabled)');

  @override
  Future<void> releaseCover() async {
    calls.add('releaseCover');
    onRelease?.call();
  }
}

class MemoryStore implements PrivacyPreferenceStore {
  MemoryStore([Map<String, bool>? initial]) : values = {...?initial};
  final Map<String, bool> values;

  /// A Keychain that can't be read (as opposed to one with nothing in it).
  bool failReads = false;

  @override
  Future<bool?> read(String key) async {
    if (failReads) throw Exception('keychain unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, bool value) async => values[key] = value;
}

void main() {
  late FakeAuthenticator auth;
  late FakeCover cover;
  late MemoryStore store;
  late DateTime clock;

  AppLockController build({bool enabled = true}) {
    auth = FakeAuthenticator();
    cover = FakeCover();
    store = MemoryStore({lockEnabledKey: enabled});
    clock = DateTime(2026, 11, 4, 9);
    return AppLockController(
      authenticator: auth,
      store: store,
      now: () => clock,
      cover: cover,
      waitForFrame: () async {},
    );
  }

  Future<AppLockController> launched({bool enabled = true}) async {
    final lock = build(enabled: enabled);
    await lock.load();
    await Future<void>.delayed(Duration.zero);
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
      auth.hold = Completer<bool>();
      final pending = lock.requireReauth('Export your notebook');
      await Future<void>.delayed(Duration.zero);
      expect(lock.authenticating, isTrue);
      background(lock, kAppLockGracePeriod * 2);
      auth.hold!.complete(true);
      expect(await pending, isTrue);
      expect(lock.status, AppLockStatus.unlocked);
    });
  });

  group('native cover', () {
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('is told the lock state, true on a read error', () async {
      final on = await launched();
      expect(cover.calls, ['setLockEnabled(true)', 'releaseCover']);
      expect(on.enabled, isTrue);

      final off = build(enabled: false);
      await off.load();
      expect(cover.calls.first, 'setLockEnabled(false)');

      final broken = build();
      store.failReads = true;
      await broken.load();
      expect(cover.calls.first, 'setLockEnabled(true)');
    });

    test('is told when the lock is turned on and off', () async {
      final lock = await launched(enabled: false);
      cover.calls.clear();
      await lock.enable();
      expect(cover.calls, contains('setLockEnabled(true)'));
      cover.calls.clear();
      await lock.disable();
      expect(cover.calls, contains('setLockEnabled(false)'));
    });

    test('a resume with the lock off never touches the cover', () async {
      final lock = await launched(enabled: false);
      cover.calls.clear();
      background(lock, const Duration(hours: 1));
      await settle();
      expect(cover.calls, isEmpty);
    });

    test('a resume with the lock on releases once the decision is made',
        () async {
      final lock = await launched();
      await lock.unlock();
      await settle();
      cover.calls.clear();
      background(lock, kAppLockGracePeriod);
      await settle();
      expect(cover.calls, ['releaseCover']);
      expect(lock.status, AppLockStatus.locked);
    });

    test('releases after a failed Face ID, so the lock screen shows', () async {
      final lock = await launched();
      cover.calls.clear();
      auth.passes = false;
      expect(await lock.unlock(), isFalse);
      await settle();
      expect(cover.calls, ['releaseCover']);
      expect(lock.status, AppLockStatus.locked);
    });

    test('releases after a passed Face ID too', () async {
      final lock = await launched();
      cover.calls.clear();
      expect(await lock.unlock(), isTrue);
      await settle();
      expect(cover.calls, ['releaseCover']);
    });
  });

  group('unreadable Keychain', () {
    test('a missing key means off', () async {
      auth = FakeAuthenticator();
      store = MemoryStore();
      final lock = AppLockController(authenticator: auth, store: store);
      await lock.load();
      expect(lock.status, AppLockStatus.unlocked);
      expect(lock.loadFailed, isFalse);
    });

    test('a read error stays locked, not unlocked', () async {
      final lock = build();
      store.failReads = true;
      await lock.load();
      expect(lock.status, AppLockStatus.locked);
      expect(lock.loadFailed, isTrue);
    });

    test('unlock retries the read first and fails while it still errors',
        () async {
      final lock = build();
      store.failReads = true;
      await lock.load();
      expect(await lock.unlock(), isFalse);
      expect(lock.status, AppLockStatus.locked);
      expect(auth.reasons, isEmpty);
    });

    test('once the read works, a lock that is on asks Face ID', () async {
      final lock = build();
      store.failReads = true;
      await lock.load();
      store.failReads = false;
      expect(await lock.unlock(), isTrue);
      expect(lock.loadFailed, isFalse);
      expect(auth.reasons, ['Unlock your journal']);
    });

    test('once the read works, a lock that is off just opens', () async {
      final lock = build(enabled: false);
      store.failReads = true;
      await lock.load();
      store.failReads = false;
      expect(await lock.unlock(), isTrue);
      expect(auth.reasons, isEmpty);
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

    test('asks even when the app lock is off', () async {
      final lock = await launched(enabled: false);
      expect(await lock.requireReauth('Export your notebook'), isTrue);
      expect(auth.reasons, ['Export your notebook']);
      auth.passes = false;
      expect(await lock.requireReauth('Export your notebook'), isFalse);
    });

    test('passes without asking only when the device has nothing to ask with',
        () async {
      final lock = await launched(enabled: false);
      auth.available = false;
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
        lockClockProvider.overrideWithValue(() => clock),
        privacyCoverProvider.overrideWithValue(cover),
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

    testWidgets('content is never visible from leaving until the lock decides',
        (tester) async {
      await pump(tester, passes: true);
      final binding = tester.binding;
      expect(find.text('journal text'), findsOneWidget);

      Future<void> step(AppLifecycleState state) async {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }

      // Leaving: covered from the first event, so the frame iOS keeps is blank.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        await step(state);
        expect(find.text('journal text'), findsNothing, reason: '$state');
      }

      // Back after the grace period: locked, and the content stays hidden.
      auth.passes = false;
      clock = clock.add(kAppLockGracePeriod);
      await step(AppLifecycleState.hidden);
      await step(AppLifecycleState.inactive);
      expect(find.text('journal text'), findsNothing);
      await step(AppLifecycleState.resumed);
      expect(find.text('journal text'), findsNothing);
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('journal text'), findsNothing);

      // Passing shows it again.
      auth.passes = true;
      await tester.tap(find.byKey(const Key('unlockButton')));
      await tester.pumpAndSettle();
      expect(find.text('journal text'), findsOneWidget);
    });

    testWidgets('a quick return lifts the cover with no lock screen',
        (tester) async {
      await pump(tester, passes: true);
      final binding = tester.binding;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(find.text('journal text'), findsNothing);
      }
      clock = clock.add(const Duration(minutes: 1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('lockScreen')), findsNothing);
      expect(find.text('journal text'), findsOneWidget);
    });

    testWidgets('a Keychain read error shows the lock screen, not the app',
        (tester) async {
      build();
      store.failReads = true;
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
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
      expect(find.text('journal text'), findsNothing);
      expect(find.text("Couldn't check your lock setting."), findsOneWidget);
    });

    testWidgets('the cover is released only after the frame showing the lock',
        (tester) async {
      await pump(tester, passes: true);
      final binding = tester.binding;
      var lockScreenUp = false;
      cover.onRelease = () => lockScreenUp =
          find.byKey(const Key('lockScreen')).evaluate().isNotEmpty;
      cover.calls.clear();
      auth.passes = false;

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      clock = clock.add(kAppLockGracePeriod);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // Decided, but no frame has been presented yet: the cover stays.
      await tester.idle();
      expect(cover.calls, isNot(contains('releaseCover')));

      await tester.pump(); // the frame that shows the lock screen
      expect(cover.calls, isNot(contains('releaseCover')));
      await tester.pump(); // and one more
      await tester.idle();
      expect(cover.calls, contains('releaseCover'));
      expect(lockScreenUp, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('a quick resume with the lock off has no cover traffic',
        (tester) async {
      await pump(tester, enabled: false);
      cover.calls.clear();
      final binding = tester.binding;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(cover.calls, isEmpty);
      expect(find.text('journal text'), findsOneWidget);
    });

    testWidgets('a failed Face ID releases the cover onto the lock screen',
        (tester) async {
      await pump(tester); // launch prompt fails
      cover.calls.clear();
      await tester.tap(find.byKey(const Key('unlockButton')));
      await tester.pumpAndSettle();
      expect(cover.calls, contains('releaseCover'));
      expect(find.byKey(const Key('lockScreen')), findsOneWidget);
    });
  });
}

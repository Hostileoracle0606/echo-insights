// LM-116: "Delete my account" in the privacy sheet. Face ID first, then a
// confirmation screen; on success the phone is cleaned and signed out and
// login says the account is deleted. A failure keeps everything.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/auth_provider.dart';
import 'package:lumen/providers/export_provider.dart';
import 'package:lumen/providers/login_notice_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/screens/dashboard/delete_account_screen.dart';
import 'package:lumen/screens/dashboard/privacy_sheet.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/security/privacy_cover.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:lumen/services/account_deletion_service.dart';
import 'package:lumen/services/journal_export_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_delete_account_gateway.dart';
import 'support/fake_deletion_pending_store.dart';

class _Lock implements LockAuthenticator {
  bool passes = true;
  final reasons = <String>[];
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    reasons.add(reason);
    return passes;
  }
}

class _Cover extends PrivacyCoverChannel {
  @override
  Future<void> setLockEnabled(bool enabled) async {}
  @override
  Future<void> releaseCover() async {}
}

class _Store implements PrivacyPreferenceStore {
  @override
  Future<bool?> read(String key) async => null;
  @override
  Future<void> write(String key, bool value) async {}
}

/// Stands in for the router's login page: the first route, showing the
/// notice the delete flow leaves for it.
class _LoginStandIn extends ConsumerWidget {
  const _LoginStandIn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(loginNoticeProvider);
    return Scaffold(
      body: Column(
        children: [
          const Text('login stand-in'),
          if (notice != null) Text(notice, key: const Key('standInNotice')),
          TextButton(
            key: const Key('openSheet'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: PrivacySheet()),
              ),
            ),
            child: const Text('open'),
          ),
        ],
      ),
    );
  }
}

UserIdentity _identity(String provider) => UserIdentity(
      id: '$provider-id',
      userId: 'user-1',
      identityId: '$provider-identity',
      identityData: const {},
      provider: provider,
      createdAt: null,
      lastSignInAt: null,
    );

void main() {
  late _Lock lock;
  late FakeAuthGateway auth;
  late FakeDeleteAccountGateway gateway;
  late FakeDeletionPendingStore store;
  late int cleanups;
  late int exportFetches;
  late AppleCredential? apple;

  setUp(() {
    exportFetches = 0;
    apple = const AppleCredential(
      identityToken: 'id-token',
      authorizationCode: 'fresh-code',
    );
    lock = _Lock();
    auth = FakeAuthGateway();
    gateway = FakeDeleteAccountGateway();
    store = FakeDeletionPendingStore();
    cleanups = 0;
  });

  Future<void> pump(WidgetTester t) async {
    t.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final authService = AccountAuthService(
      auth,
      appleCredential: (_) async => apple,
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountAuthServiceProvider.overrideWithValue(authService),
          accountDeletionServiceProvider.overrideWithValue(
            AccountDeletionService(
              auth: authService,
              gateway: gateway,
              store: store,
              cleanup: () async => cleanups += 1,
            ),
          ),
          lockAuthenticatorProvider.overrideWithValue(lock),
          privacyCoverProvider.overrideWithValue(_Cover()),
          privacyPreferenceStoreProvider.overrideWithValue(_Store()),
          shareVaultProvider
              .overrideWithValue((vault, {Rect? origin}) async {}),
          journalExportServiceProvider.overrideWithValue(
            JournalExportService(
              rpc: (fn, params) async => throw StateError('offline'),
              listNotebookIds: () async {
                exportFetches += 1;
                throw StateError('offline');
              },
            ),
          ),
        ],
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: const _LoginStandIn(),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('openSheet')));
    await t.pumpAndSettle();
  }

  final tile = find.byKey(const Key('deleteAccountTile'));
  final confirm = find.byKey(const Key('confirmDeleteAccount'));
  final cancel = find.byKey(const Key('cancelDeleteAccount'));

  Future<void> openConfirmation(WidgetTester t) async {
    await t.ensureVisible(tile);
    await t.pumpAndSettle();
    await t.tap(tile);
    await t.pumpAndSettle();
  }

  String allText(WidgetTester t) => t
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
      .join('\n');

  testWidgets('Privacy sheet shows a "Delete my account" row below Export',
      (t) async {
    await pump(t);
    expect(tile, findsOneWidget);
    expect(find.text('Delete my account'), findsOneWidget);
    final export = find.byKey(const Key('exportJournalTile'));
    expect(t.getTopLeft(tile).dy, greaterThan(t.getTopLeft(export).dy));
  });

  testWidgets('failed re-auth opens nothing and deletes nothing', (t) async {
    lock.passes = false;
    await pump(t);
    await openConfirmation(t);

    expect(lock.reasons, ['Delete your account']);
    expect(find.byType(DeleteAccountScreen), findsNothing);
    expect(gateway.events, isEmpty);
    expect(cleanups, 0);
  });

  testWidgets(
      'confirmation screen text names conversations, cards, map, brief and '
      'shared log, says it cannot be undone, links to Export my journal',
      (t) async {
    await pump(t);
    await openConfirmation(t);

    expect(lock.reasons, ['Delete your account']);
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    final text = allText(t).toLowerCase();
    for (final word in [
      'conversations',
      'cards',
      'map',
      'brief',
      'what lumen shared',
      'cannot be undone',
    ]) {
      expect(text, contains(word));
    }
    final link = find.byKey(const Key('deleteAccountExportLink'));
    expect(link, findsOneWidget);
    expect(
      find.descendant(
          of: link, matching: find.textContaining('Export my journal')),
      findsOneWidget,
    );
    expect(confirm, findsOneWidget);
    expect(cancel, findsOneWidget);
    expect(gateway.events, isEmpty, reason: 'nothing happens until confirm');
  });

  testWidgets('the export link goes back to the sheet and starts the export',
      (t) async {
    await pump(t);
    await openConfirmation(t);
    await t.tap(find.byKey(const Key('deleteAccountExportLink')));
    await t.pumpAndSettle();

    expect(find.byType(DeleteAccountScreen), findsNothing);
    expect(find.byKey(const Key('exportJournalTile')), findsOneWidget);
    expect(lock.reasons, ['Delete your account', 'Export your journal']);
    expect(exportFetches, 1);
    expect(gateway.events, isEmpty);
    expect(cleanups, 0);
  });

  testWidgets('cancel deletes nothing and keeps local data', (t) async {
    await pump(t);
    await openConfirmation(t);
    await t.tap(cancel);
    await t.pumpAndSettle();

    expect(find.byType(DeleteAccountScreen), findsNothing);
    expect(tile, findsOneWidget, reason: 'back on the privacy sheet');
    expect(gateway.events, isEmpty);
    expect(cleanups, 0);
  });

  testWidgets(
      'success runs signedOutCleanup (spy), signs out, pops to login and '
      'shows "Your account is deleted"', (t) async {
    await pump(t);
    await openConfirmation(t);
    await t.tap(confirm);
    await t.pumpAndSettle();

    expect(gateway.events, ['refreshSession', 'call', 'signOutLocal']);
    expect(gateway.sentCodes, [null]);
    expect(cleanups, 1);
    expect(find.byType(DeleteAccountScreen), findsNothing);
    expect(find.byType(PrivacySheet), findsNothing);
    expect(find.text('login stand-in'), findsOneWidget);
    expect(find.textContaining('Your account is deleted'), findsOneWidget);
    expect(find.textContaining('Sign in with Apple'), findsNothing);
  });

  testWidgets(
      'Apple user success without revocation shows how to remove Lumen under '
      'Settings, Apple ID, Sign in with Apple', (t) async {
    auth.identityList = [_identity('apple')];
    gateway.result = (queued: true, alreadyQueued: false, appleRevoked: false);
    await pump(t);
    await openConfirmation(t);
    await t.tap(confirm);
    await t.pumpAndSettle();

    expect(gateway.sentCodes, ['fresh-code']);
    expect(cleanups, 1);
    final notice = t.widget<Text>(find.byKey(const Key('standInNotice'))).data!;
    expect(notice, contains('Your account is deleted'));
    expect(notice, contains('Settings'));
    expect(notice, contains('Apple ID'));
    expect(notice, contains('Sign in with Apple'));
    expect(notice, contains('Lumen'));
  });

  testWidgets(
      'failure keeps the person signed in, keeps local data, shows '
      'retry', (t) async {
    gateway.callError = StateError('server body: secret');
    await pump(t);
    await openConfirmation(t);
    await t.tap(confirm);
    await t.pumpAndSettle();

    expect(gateway.events, isNot(contains('signOutLocal')));
    expect(cleanups, 0);
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    expect(find.byKey(const Key('deleteAccountProblem')), findsOneWidget);
    expect(
      find.text('We could not confirm that your account is being deleted. '
          'Check your connection and try again. If you close Lumen now, it '
          'will try again the next time you open it.'),
      findsOneWidget,
    );
    expect(find.textContaining('secret'), findsNothing);
    expect(find.descendant(of: confirm, matching: find.text('Try again')),
        findsOneWidget);
    expect(store.value, isNotNull, reason: 'the marker is kept');

    // Retry works once the connection is back.
    gateway.callError = null;
    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(cleanups, 1);
    expect(find.textContaining('Your account is deleted'), findsOneWidget);
    expect(gateway.sentRequestIds.toSet(), hasLength(1),
        reason: 'the retry resends the same request id');
    expect(store.value, isNull);
  });

  testWidgets(
      'reply lost: nothing is wiped; the retry gets already_queued and the '
      'app wipes', (t) async {
    gateway.replies = <Object>[
      TimeoutException('reply lost'),
      (queued: true, alreadyQueued: true, appleRevoked: null),
    ];
    await pump(t);
    await openConfirmation(t);
    await t.tap(confirm);
    await t.pumpAndSettle();

    expect(cleanups, 0);
    expect(gateway.events, isNot(contains('signOutLocal')));
    expect(find.byKey(const Key('deleteAccountProblem')), findsOneWidget);

    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(gateway.sentRequestIds, hasLength(2));
    expect(gateway.sentRequestIds.toSet(), hasLength(1));
    expect(cleanups, 1);
    expect(gateway.events.last, 'signOutLocal');
    expect(find.textContaining('Your account is deleted'), findsOneWidget);
  });

  testWidgets('a double tap on delete calls the function once', (t) async {
    final gate = Completer<void>();
    gateway.callGate = gate.future;
    await pump(t);
    await openConfirmation(t);
    // Both taps land before the button rebuilds as disabled.
    await t.tap(confirm);
    await t.tap(confirm);
    await t.pump();
    gate.complete();
    await t.pumpAndSettle();

    expect(gateway.sentCodes, hasLength(1));
    expect(cleanups, 1);
  });

  testWidgets(
      'Apple sheet cancelled: nothing deleted, spinner cleared, '
      'still on the screen', (t) async {
    auth.identityList = [_identity('apple')];
    apple = null;
    await pump(t);
    await openConfirmation(t);
    await t.tap(confirm);
    await t.pumpAndSettle();

    expect(gateway.events, isEmpty);
    expect(cleanups, 0);
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(t.widget<FilledButton>(confirm).onPressed, isNotNull);
    expect(find.byKey(const Key('deleteAccountProblem')), findsNothing);
  });

  testWidgets('the login screen shows the notice the delete flow left',
      (t) async {
    final container = ProviderContainer(overrides: [
      accountAuthServiceProvider.overrideWithValue(AccountAuthService(auth)),
    ]);
    addTearDown(container.dispose);
    container.read(loginNoticeProvider.notifier).show(deletedNotice);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: const LoginScreen(),
        ),
      ),
    );
    await t.pump();
    expect(find.byKey(const Key('loginNotice')), findsOneWidget);
    expect(find.textContaining('Your account is deleted'), findsOneWidget);
  });

  test('the notice is cleared once someone signs in again', () async {
    final users = StreamController<User?>();
    addTearDown(users.close);
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith((ref) => users.stream),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(loginNoticeProvider, (_, __) {});
    addTearDown(sub.close);

    container.read(loginNoticeProvider.notifier).show(deletedNotice);
    users.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(loginNoticeProvider), deletedNotice);

    users.add(fakeUser());
    await Future<void>.delayed(Duration.zero);
    expect(container.read(loginNoticeProvider), isNull);
  });
}

// Account deletion queue (follow-up to LM-116): a "deletion pending" marker
// left by a delete whose reply never arrived is resent on the next launch.
// The phone is wiped only once the server answers "queued", or when its
// session is already gone.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/deletion_resume.dart';
import 'package:lumen/providers/login_notice_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/security/fresh_install.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:lumen/services/account_deletion_service.dart';
import 'package:lumen/services/deletion_pending_store.dart';
import 'package:lumen/services/session_brief_service.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_delete_account_gateway.dart';
import 'support/fake_deletion_pending_store.dart';

class _NoBriefs implements SessionBriefService {
  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: false, brief: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> events;
  late FakeDeleteAccountGateway gateway;
  late FakeDeletionPendingStore store;
  late int cleanups;

  ProviderContainer launch() {
    final container = ProviderContainer(overrides: [
      accountDeletionServiceProvider.overrideWithValue(AccountDeletionService(
        auth: AccountAuthService(FakeAuthGateway()),
        gateway: gateway,
        store: store,
        timeout: const Duration(milliseconds: 50),
      )),
      signedOutCleanupProvider.overrideWithValue(() => cleanups += 1),
    ]);
    addTearDown(container.dispose);
    // The login screen listens for the whole run.
    final sub = container.listen(loginNoticeProvider, (_, __) {});
    addTearDown(sub.close);
    return container;
  }

  setUp(() {
    events = [];
    gateway = FakeDeleteAccountGateway(events: events);
    store = FakeDeletionPendingStore(events: events);
    cleanups = 0;
  });

  test('on launch with no marker nothing is called', () async {
    final container = launch();

    expect(await resumePendingDeletion(container), isNull);
    expect(events, isEmpty);
    expect(cleanups, 0);
    expect(container.read(loginNoticeProvider), isNull);
  });

  test('marker is resent on launch and wipes only after the server answers '
      'queued', () async {
    store.value = 'stored-id';
    final gate = Completer<void>();
    gateway.callGate = gate.future;
    gateway.result = (queued: true, alreadyQueued: true, appleRevoked: null);
    final container = launch();

    final run = resumePendingDeletion(container);
    await pumpEventQueue();
    expect(events, ['refreshSession', 'call']);
    expect(cleanups, 0, reason: 'nothing wiped before the answer');
    gate.complete();

    expect(await run, DeleteOutcome.deleted);
    expect(gateway.sentRequestIds, ['stored-id']);
    expect(events, ['refreshSession', 'call', 'markerClear', 'signOutLocal']);
    expect(cleanups, 1);
    expect(container.read(loginNoticeProvider), deletedNotice);
  });

  test('on launch with a marker and a dead session the app wipes and signs '
      'out', () async {
    store.value = 'stored-id';
    gateway.refreshError = const DeletionSessionGone();
    final container = launch();

    expect(await resumePendingDeletion(container), DeleteOutcome.deleted);
    expect(events, ['refreshSession', 'markerClear', 'signOutLocal']);
    expect(store.value, isNull);
    expect(cleanups, 1);
    expect(container.read(loginNoticeProvider), deletedNotice);
  });

  test('Apple not revoked on the resend shows the Apple ID steps', () async {
    store.value = 'stored-id';
    gateway.result = (queued: true, alreadyQueued: false, appleRevoked: false);
    final container = launch();

    expect(await resumePendingDeletion(container),
        DeleteOutcome.deletedAppleNotRevoked);
    expect(container.read(loginNoticeProvider), deletedAppleNotRevokedNotice);
  });

  test('a network error on launch keeps the marker and local data', () async {
    store.value = 'stored-id';
    gateway.callError = TimeoutException('offline');
    final container = launch();

    expect(await resumePendingDeletion(container), isNull);
    expect(store.value, 'stored-id');
    expect(events, isNot(contains('signOutLocal')));
    expect(cleanups, 0);
    expect(container.read(loginNoticeProvider), isNull);
  });

  test('never throws, even with no Supabase behind the providers', () async {
    final container = ProviderContainer(overrides: [
      accountDeletionServiceProvider
          .overrideWith((ref) => throw StateError('not initialised')),
    ]);
    addTearDown(container.dispose);

    expect(await resumePendingDeletion(container), isNull);
  });

  test('signing out (or switching account) drops a pending marker', () async {
    store.value = 'stored-id';
    final container = ProviderContainer(overrides: [
      openingPrepProvider.overrideWithValue(OpeningPrep(_NoBriefs())),
      deletionPendingStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    container.read(signedOutCleanupProvider)();
    await pumpEventQueue();

    expect(store.value, isNull,
        reason: 'a later account must never be sent the old request id');
  });

  test('the marker lives in the Keychain and a reinstall wipes it', () {
    expect(KeychainDeletionPendingStore.key, 'account.deletion_pending');
    expect(lumenKeychainKeys, contains(KeychainDeletionPendingStore.key));
  });
}

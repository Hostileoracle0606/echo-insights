// LM-116: deleting the account from the app. The service runs Apple's sheet
// again for Apple users (a fresh, single-use authorization code), refreshes
// the session so the function sees a new token, calls `delete-account`, and
// signs this phone out only after the server says the account is gone.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:lumen/services/account_deletion_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_delete_account_gateway.dart';
import 'support/fake_deletion_pending_store.dart';

UserIdentity _identity(String provider) => UserIdentity(
      id: '$provider-id',
      userId: 'user-1',
      identityId: '$provider-identity',
      identityData: const {},
      provider: provider,
      createdAt: null,
      lastSignInAt: null,
      updatedAt: null,
    );

void main() {
  late FakeAuthGateway auth;
  late FakeDeleteAccountGateway gateway;
  late List<String> events;
  late AppleCredential? apple;
  late FakeDeletionPendingStore store;
  late int ids;

  AccountDeletionService service() => AccountDeletionService(
        auth: AccountAuthService(
          auth,
          appleCredential: (_) async {
            events.add('appleSheet');
            return apple;
          },
        ),
        gateway: gateway,
        store: store,
        newRequestId: () => 'request-${++ids}',
      );

  setUp(() {
    events = [];
    ids = 0;
    auth = FakeAuthGateway();
    gateway = FakeDeleteAccountGateway(events: events);
    store = FakeDeletionPendingStore(events: events);
    apple = const AppleCredential(
      identityToken: 'id-token',
      authorizationCode: 'fresh-code',
    );
  });

  test('non-apple user: calls gateway with no code, returns deleted', () async {
    auth.identityList = [_identity('email')];

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deleted);
    expect(events, [
      'markerWrite',
      'refreshSession',
      'call',
      'markerClear',
      'signOutLocal',
    ]);
    expect(gateway.sentCodes, [null]);
  });

  test('apple user: re-runs Apple and sends the fresh authorizationCode',
      () async {
    auth.identityList = [_identity('apple')];
    gateway.result = (queued: true, alreadyQueued: false, appleRevoked: true);

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deleted);
    // The code is single-use and lives 5 minutes: the sheet runs right
    // before the refresh and the call, never earlier.
    expect(events, [
      'appleSheet',
      'markerWrite',
      'refreshSession',
      'call',
      'markerClear',
      'signOutLocal',
    ]);
    expect(gateway.sentCodes, ['fresh-code']);
  });

  test('apple sheet cancelled: nothing called, cancelled', () async {
    auth.identityList = [_identity('apple')];
    apple = null;

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.cancelled);
    expect(events, ['appleSheet'], reason: 'no marker is left behind');
    expect(store.value, isNull);
    expect(gateway.sentCodes, isEmpty);
  });

  test('server says deleted but apple not revoked -> deletedAppleNotRevoked',
      () async {
    auth.identityList = [_identity('apple')];
    gateway.result = (queued: true, alreadyQueued: false, appleRevoked: false);

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deletedAppleNotRevoked);
    expect(events.last, 'signOutLocal');
  });

  test(
      'gateway failure -> throws AccountAuthException, signOutLocal not called',
      () async {
    for (final setup in <void Function()>[
      () => gateway.callError = StateError('server said: secret-body'),
      () => gateway.result =
          (queued: false, alreadyQueued: false, appleRevoked: null),
      () => gateway.refreshError = StateError('refresh token secret'),
    ]) {
      events.clear();
      gateway = FakeDeleteAccountGateway(events: events);
      store = FakeDeletionPendingStore(events: events);
      setup();

      await expectLater(
        service().deleteAccount(),
        throwsA(
          isA<AccountAuthException>()
              .having(
                  (e) => e.message,
                  'message',
                  'Could not delete your account. Check your connection and '
                      'try again.')
              .having((e) => e.message, 'no server text',
                  isNot(contains('secret'))),
        ),
      );
      expect(events, isNot(contains('signOutLocal')));
      expect(events, isNot(contains('markerClear')));
      expect(store.value, isNotNull, reason: 'the marker is kept');
    }
  });

  test('a call that never answers times out as failure, no sign-out', () async {
    gateway.callGate = Completer<void>().future;
    final slow = AccountDeletionService(
      auth: AccountAuthService(auth),
      gateway: gateway,
      store: store,
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      slow.deleteAccount(),
      throwsA(isA<AccountAuthException>().having(
          (e) => e.message, 'message', AccountDeletionService.failure.message)),
    );
    expect(events, ['markerWrite', 'refreshSession', 'call']);
    expect(store.value, isNotNull);
  });

  test('a sign-out error after the account is gone still reports deleted',
      () async {
    gateway.signOutError = StateError('session already gone');

    expect(await service().deleteAccount(), DeleteOutcome.deleted);
  });
  group('the deletion pending marker', () {
    test('request id is generated once and the same id is resent on retry',
        () async {
      gateway.callError = StateError('offline');
      await expectLater(
          service().deleteAccount(), throwsA(isA<AccountAuthException>()));
      gateway.callError = null;

      expect(await service().deleteAccount(), DeleteOutcome.deleted);

      expect(ids, 1, reason: 'one id for the whole deletion');
      expect(gateway.sentRequestIds, ['request-1', 'request-1']);
      expect(store.value, isNull);
    });

    test('reply lost, retry with the same id gets already_queued and the app '
        'wipes', () async {
      gateway.replies = <Object>[
        TimeoutException('reply lost'),
        (queued: true, alreadyQueued: true, appleRevoked: null),
      ];
      await expectLater(
          service().deleteAccount(), throwsA(isA<AccountAuthException>()));
      expect(events, isNot(contains('signOutLocal')));
      expect(store.value, 'request-1');

      expect(await service().deleteAccount(), DeleteOutcome.deleted);
      expect(gateway.sentRequestIds, ['request-1', 'request-1']);
      expect(events.last, 'signOutLocal');
      expect(store.value, isNull);
    });

    test('marker written before the call and cleared only after queued',
        () async {
      String? markerDuringCall;
      final gate = Completer<void>();
      gateway.callGate = gate.future;
      final run = service().deleteAccount();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      markerDuringCall = store.value;
      gate.complete();
      await run;

      expect(markerDuringCall, 'request-1');
      expect(events.indexOf('markerWrite'), lessThan(events.indexOf('call')));
      expect(
          events.indexOf('markerClear'), greaterThan(events.indexOf('call')));
      expect(events.indexOf('markerClear'),
          lessThan(events.indexOf('signOutLocal')));
    });

    test('failure (network) keeps the marker and local data', () async {
      gateway.callError = TimeoutException('network');
      await expectLater(
          service().deleteAccount(), throwsA(isA<AccountAuthException>()));
      expect(store.value, 'request-1');
      expect(events, isNot(contains('markerClear')));
      expect(events, isNot(contains('signOutLocal')));
    });

    test('a marker that cannot be written stops before the call', () async {
      store.writeError = StateError('keychain');
      await expectLater(
          service().deleteAccount(), throwsA(isA<AccountAuthException>()));
      expect(events, isNot(contains('call')));
    });
  });

  group('resumePending', () {
    test('no marker: nothing is called, null', () async {
      expect(await service().resumePending(), isNull);
      expect(events, isEmpty);
    });

    test('marker is resent and wipes only after the server answers queued',
        () async {
      store.value = 'stored-id';
      gateway.result = (queued: true, alreadyQueued: true, appleRevoked: null);

      expect(await service().resumePending(), DeleteOutcome.deleted);
      expect(events,
          ['refreshSession', 'call', 'markerClear', 'signOutLocal']);
      expect(gateway.sentRequestIds, ['stored-id']);
      expect(gateway.sentCodes, [null], reason: 'Apple codes are single-use');
      expect(ids, 0);
    });

    test('Apple not revoked on the resend is reported', () async {
      store.value = 'stored-id';
      gateway.result = (queued: true, alreadyQueued: false, appleRevoked: false);
      expect(await service().resumePending(),
          DeleteOutcome.deletedAppleNotRevoked);
    });

    test('a dead session (refresh) is treated as deleted', () async {
      store.value = 'stored-id';
      gateway.refreshError = const DeletionSessionGone();

      expect(await service().resumePending(), DeleteOutcome.deleted);
      expect(events, ['refreshSession', 'markerClear', 'signOutLocal']);
      expect(store.value, isNull);
    });

    test('a dead session (the function says 401) is treated as deleted',
        () async {
      store.value = 'stored-id';
      gateway.callError = const DeletionSessionGone();

      expect(await service().resumePending(), DeleteOutcome.deleted);
      expect(store.value, isNull);
      expect(events.last, 'signOutLocal');
    });

    test('network error, timeout or not queued keeps the marker, null',
        () async {
      for (final setup in <void Function()>[
        () => gateway.refreshError = StateError('offline'),
        () => gateway.callError = TimeoutException('slow'),
        () => gateway.result =
            (queued: false, alreadyQueued: false, appleRevoked: null),
        () => gateway.callGate = Completer<void>().future,
      ]) {
        events.clear();
        gateway = FakeDeleteAccountGateway(events: events);
        store = FakeDeletionPendingStore(events: events, value: 'stored-id');
        setup();
        final quick = AccountDeletionService(
          auth: AccountAuthService(auth),
          gateway: gateway,
          store: store,
          timeout: const Duration(milliseconds: 20),
        );

        expect(await quick.resumePending(), isNull);
        expect(store.value, 'stored-id');
        expect(events, isNot(contains('signOutLocal')));
      }
    });

    test('an unreadable marker store is null and calls nothing', () async {
      store.readError = StateError('keychain locked');
      expect(await service().resumePending(), isNull);
      expect(events, isEmpty);
    });
  });
}

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

  AccountDeletionService service() => AccountDeletionService(
        auth: AccountAuthService(
          auth,
          appleCredential: (_) async {
            events.add('appleSheet');
            return apple;
          },
        ),
        gateway: gateway,
      );

  setUp(() {
    events = [];
    auth = FakeAuthGateway();
    gateway = FakeDeleteAccountGateway(events: events);
    apple = const AppleCredential(
      identityToken: 'id-token',
      authorizationCode: 'fresh-code',
    );
  });

  test('non-apple user: calls gateway with no code, returns deleted', () async {
    auth.identityList = [_identity('email')];

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deleted);
    expect(events, ['refreshSession', 'call', 'signOutLocal']);
    expect(gateway.sentCodes, [null]);
  });

  test('apple user: re-runs Apple and sends the fresh authorizationCode',
      () async {
    auth.identityList = [_identity('apple')];
    gateway.result = (deleted: true, appleRevoked: true);

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deleted);
    // The code is single-use and lives 5 minutes: the sheet runs right
    // before the refresh and the call, never earlier.
    expect(events, ['appleSheet', 'refreshSession', 'call', 'signOutLocal']);
    expect(gateway.sentCodes, ['fresh-code']);
  });

  test('apple sheet cancelled: nothing called, cancelled', () async {
    auth.identityList = [_identity('apple')];
    apple = null;

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.cancelled);
    expect(events, ['appleSheet']);
    expect(gateway.sentCodes, isEmpty);
  });

  test('server says deleted but apple not revoked -> deletedAppleNotRevoked',
      () async {
    auth.identityList = [_identity('apple')];
    gateway.result = (deleted: true, appleRevoked: false);

    final outcome = await service().deleteAccount();

    expect(outcome, DeleteOutcome.deletedAppleNotRevoked);
    expect(events.last, 'signOutLocal');
  });

  test(
      'gateway failure -> throws AccountAuthException, signOutLocal not called',
      () async {
    for (final setup in <void Function()>[
      () => gateway.callError = StateError('server said: secret-body'),
      () => gateway.result = (deleted: false, appleRevoked: null),
      () => gateway.refreshError = StateError('refresh token secret'),
    ]) {
      events.clear();
      gateway = FakeDeleteAccountGateway(events: events);
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
    }
  });

  test('a call that never answers times out as failure, no sign-out', () async {
    gateway.callGate = Completer<void>().future;
    final slow = AccountDeletionService(
      auth: AccountAuthService(auth),
      gateway: gateway,
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      slow.deleteAccount(),
      throwsA(isA<AccountAuthException>().having(
          (e) => e.message, 'message', AccountDeletionService.failure.message)),
    );
    expect(events, ['refreshSession', 'call']);
  });

  test('a sign-out error after the account is gone still reports deleted',
      () async {
    gateway.signOutError = StateError('session already gone');

    expect(await service().deleteAccount(), DeleteOutcome.deleted);
  });
}

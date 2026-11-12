// LM-58: Sign in with Apple, linking, passkeys and the device list, against a
// fake Supabase Auth. The device RPCs are proven against Postgres by
// supabase/tests/database/device_sessions_test.sql.
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_auth_gateway.dart';

final _now = DateTime.utc(2026, 11, 12, 10);

void main() {
  late FakeAuthGateway gateway;
  late String? hashSeen;
  late AppleCredential? apple;

  AccountAuthService build() => AccountAuthService(
        gateway,
        appleCredential: (hashed) async {
          hashSeen = hashed;
          return apple;
        },
        now: () => _now,
      );

  setUp(() {
    gateway = FakeAuthGateway();
    hashSeen = null;
    apple = const AppleCredential(identityToken: 'apple-id-token');
  });

  group('Sign in with Apple', () {
    test(
        'asks Apple with the SHA-256 of the nonce and Supabase with the raw one',
        () async {
      await build().signInWithApple();

      expect(hashSeen, sha256.convert('raw-nonce-123'.codeUnits).toString());
      expect(hashSeen, isNot('raw-nonce-123'));
      expect(gateway.signedInNonce, 'raw-nonce-123');
      expect(gateway.signedInToken, 'apple-id-token');
    });

    test('a cancelled sheet is not an error and signs nothing in', () async {
      apple = null;

      expect(await build().signInWithApple(), SignInOutcome.cancelled);
      expect(gateway.calls, isEmpty);
    });

    test('a missing identity token is refused without calling Supabase',
        () async {
      apple = const AppleCredential(identityToken: null);

      await expectLater(
        build().signInWithApple(),
        throwsA(isA<AccountAuthException>()),
      );
      expect(gateway.calls, isEmpty);
    });

    test('a server failure propagates', () async {
      gateway.signInError = const AuthException('bad nonce');

      await expectLater(
          build().signInWithApple(), throwsA(isA<AuthException>()));
    });

    test('a brand-new user is a new account', () async {
      gateway.response = AuthResponse(
        user: fakeUser(
          created: _now.subtract(const Duration(seconds: 2)),
          lastSignIn: _now.subtract(const Duration(seconds: 2)),
        ),
      );

      expect(await build().signInWithApple(), SignInOutcome.newAccount);
    });

    test('an existing account (older, or auto-linked by email) is not new',
        () async {
      gateway.response = AuthResponse(
        user: fakeUser(
          created: _now.subtract(const Duration(days: 40)),
          lastSignIn: _now,
        ),
      );

      expect(await build().signInWithApple(), SignInOutcome.signedIn);
    });

    test('saves the name Apple sent the first time', () async {
      apple = const AppleCredential(
        identityToken: 't',
        givenName: 'Ada',
        familyName: 'Lovelace',
      );

      await build().signInWithApple();

      expect(gateway.savedName?['full_name'], 'Ada Lovelace');
    });

    test('no name from Apple (a later sign-in) saves nothing', () async {
      await build().signInWithApple();

      expect(gateway.calls, isNot(contains('setUserName')));
    });

    test('a failed name save does not fail the sign-in', () async {
      apple = const AppleCredential(identityToken: 't', givenName: 'Ada');
      gateway.nameError = StateError('offline');

      expect(await build().signInWithApple(), SignInOutcome.signedIn);
    });

    test('a hidden (privaterelay) email signs in like any other', () async {
      gateway.response = AuthResponse(
        user: fakeUser(email: 'abc123@privaterelay.appleid.com'),
      );

      expect(await build().signInWithApple(), SignInOutcome.signedIn);
    });
  });

  group('linking', () {
    test('links Apple to the signed-in account with a fresh nonce', () async {
      expect(await build().linkApple(), isTrue);

      expect(gateway.calls, ['linkApple']);
      expect(gateway.linkedToken, 'apple-id-token');
      expect(gateway.linkedNonce, 'raw-nonce-123');
      expect(hashSeen, AccountAuthService.hashNonce('raw-nonce-123'));
    });

    test('a cancelled sheet links nothing', () async {
      apple = null;

      expect(await build().linkApple(), isFalse);
      expect(gateway.calls, isEmpty);
    });

    test('an Apple ID already on another account surfaces as an error',
        () async {
      gateway.linkError = const AuthException('identity_already_exists');

      await expectLater(build().linkApple(), throwsA(isA<AuthException>()));
    });

    test('hasAppleLinked reads the account identities', () async {
      expect(await build().hasAppleLinked(), isFalse);
      gateway.identityList = [
        const UserIdentity(
          id: 'i1',
          userId: 'user-1',
          identityData: {},
          identityId: 'i1',
          provider: 'apple',
          createdAt: '2026-01-01T00:00:00Z',
          lastSignInAt: '2026-01-01T00:00:00Z',
        ),
      ];
      expect(await build().hasAppleLinked(), isTrue);
    });
  });

  group('passkeys', () {
    test('a cancelled prompt is not an error', () async {
      gateway.passkeyResponse = null;

      expect(await build().signInWithPasskey(), SignInOutcome.cancelled);
    });

    test('a passkey sign-in into an older account is a plain sign-in',
        () async {
      gateway.passkeyResponse = AuthResponse(
        user: fakeUser(created: _now.subtract(const Duration(days: 3))),
      );

      expect(await build().signInWithPasskey(), SignInOutcome.signedIn);
    });

    test('adding a passkey registers it on the signed-in account', () async {
      expect(await build().addPasskey(), isTrue);
      expect(gateway.calls, ['registerPasskey']);

      gateway.passkeyRegisters = false;
      expect(await build().addPasskey(), isFalse);
    });

    test('removing a passkey deletes it by id', () async {
      await build().removePasskey('pk-1');
      expect(gateway.calls, ['deletePasskey:pk-1']);
    });
  });

  group('devices', () {
    test('lists the caller\'s sessions with the current one marked', () async {
      gateway.rpcResult = [
        {
          'id': 's1',
          'created_at': '2026-11-01T10:00:00Z',
          'last_active_at': '2026-11-12T09:00:00Z',
          'user_agent': 'Dart/3.5 (dart:io)',
          'is_current': true,
        },
        {
          'id': 's2',
          'created_at': '2026-10-01T10:00:00Z',
          'last_active_at': null,
          'user_agent': 'Mozilla/5.0 Safari',
          'is_current': false,
        },
      ];

      final devices = await build().devices();

      expect(gateway.rpcCalls.single.$1, 'list_my_sessions');
      expect(devices.map((d) => d.isCurrent), [true, false]);
      expect(devices[0].kind, 'Lumen app');
      expect(devices[1].kind, 'Web browser');
      expect(devices[1].lastActiveAt, devices[1].createdAt);
    });

    test('signing a device out calls revoke_my_session with its id', () async {
      gateway.rpcResult = true;

      expect(await build().signOutDevice('s2'), isTrue);
      expect(gateway.rpcCalls.single.$1, 'revoke_my_session');
      expect(gateway.rpcCalls.single.$2, {'p_session_id': 's2'});
    });

    test('nothing revoked is false', () async {
      gateway.rpcResult = false;

      expect(await build().signOutDevice('s2'), isFalse);
    });
  });
}

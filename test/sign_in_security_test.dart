// ignore_for_file: experimental_member_use
// LM-58: the device list and sign-in methods in the privacy sheet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/dashboard/sign_in_security.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/security/privacy_cover.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_auth_gateway.dart';

class _Auth implements LockAuthenticator {
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

Map<String, dynamic> _row(String id, {required bool current, String? ua}) => {
      'id': id,
      'created_at': '2026-11-01T10:00:00Z',
      'last_active_at': '2026-11-12T09:00:00Z',
      'user_agent': ua ?? 'Dart/3.5 (dart:io)',
      'is_current': current,
    };

void main() {
  late FakeAuthGateway gateway;
  late _Auth lock;

  setUp(() {
    gateway = FakeAuthGateway();
    lock = _Auth();
    gateway.rpcResult = [
      _row('this', current: true),
      _row('other', current: false, ua: 'Mozilla/5.0 Safari'),
    ];
  });

  Future<void> pump(WidgetTester t, {bool passkeys = false}) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountAuthServiceProvider.overrideWithValue(
            AccountAuthService(
              gateway,
              appleCredential: (_) async =>
                  const AppleCredential(identityToken: 'tok'),
            ),
          ),
          lockAuthenticatorProvider.overrideWithValue(lock),
          privacyCoverProvider.overrideWithValue(_Cover()),
          privacyPreferenceStoreProvider.overrideWithValue(_Store()),
        ],
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
                child: SignInSecurity(passkeys: passkeys)),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('signInSecurityTile')));
    await t.pumpAndSettle();
  }

  testWidgets('nothing loads until the section is opened', (t) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountAuthServiceProvider.overrideWithValue(
            AccountAuthService(gateway),
          ),
        ],
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: const Scaffold(body: SignInSecurity()),
        ),
      ),
    );
    expect(gateway.rpcCalls, isEmpty);
  });

  testWidgets('lists devices, marks this one, offers sign out on the others',
      (t) async {
    await pump(t);

    expect(find.text('Lumen app (this device)'), findsOneWidget);
    expect(find.text('Web browser'), findsOneWidget);
    expect(find.byKey(const Key('signOutDevice-this')), findsNothing);
    expect(find.byKey(const Key('signOutDevice-other')), findsOneWidget);
  });

  testWidgets('signing a device out asks for Face ID, then revokes it',
      (t) async {
    await pump(t);

    await t.tap(find.byKey(const Key('signOutDevice-other')));
    await t.pumpAndSettle();

    expect(lock.reasons, ['Sign out a device']);
    expect(
      gateway.rpcCalls.where((c) => c.$1 == 'revoke_my_session').single.$2,
      {'p_session_id': 'other'},
    );
  });

  testWidgets('a failed Face ID revokes nothing', (t) async {
    lock.passes = false;
    await pump(t);

    await t.tap(find.byKey(const Key('signOutDevice-other')));
    await t.pumpAndSettle();

    expect(gateway.rpcCalls.map((c) => c.$1),
        isNot(contains('revoke_my_session')));
  });

  testWidgets('a failed revoke shows a plain message', (t) async {
    await pump(t);
    // The next rpc is the revoke: it fails.
    gateway.rpcResult = StateError('secret');
    await t.tap(find.byKey(const Key('signOutDevice-other')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('signInSecurityProblem')), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('linking Apple asks for Face ID first', (t) async {
    await pump(t);

    await t.tap(find.byKey(const Key('linkAppleButton')));
    await t.pumpAndSettle();

    expect(lock.reasons, ['Link your Apple ID']);
    expect(gateway.calls, contains('linkApple'));
  });

  testWidgets('linking is not attempted when Face ID fails', (t) async {
    lock.passes = false;
    await pump(t);

    await t.tap(find.byKey(const Key('linkAppleButton')));
    await t.pumpAndSettle();

    expect(gateway.calls, isEmpty);
  });

  testWidgets('an Apple ID already on another account is a plain message',
      (t) async {
    gateway.linkError = const AuthException('identity_already_exists');
    await pump(t);

    await t.tap(find.byKey(const Key('linkAppleButton')));
    await t.pumpAndSettle();

    expect(find.textContaining('may already belong to another account'),
        findsOneWidget);
    expect(find.textContaining('identity_already_exists'), findsNothing);
  });

  testWidgets('an already-linked Apple shows linked, with no button',
      (t) async {
    gateway.identityList = [
      const UserIdentity(
        id: 'i',
        userId: 'u',
        identityData: {},
        identityId: 'i',
        provider: 'apple',
        createdAt: '2026-01-01T00:00:00Z',
        lastSignInAt: '2026-01-01T00:00:00Z',
      ),
    ];
    await pump(t);

    expect(find.text('Linked to this account.'), findsOneWidget);
    expect(find.byKey(const Key('linkAppleButton')), findsNothing);
  });

  testWidgets('passkeys are hidden unless the build enables them', (t) async {
    await pump(t);
    expect(find.byKey(const Key('addPasskeyTile')), findsNothing);
  });

  testWidgets('adding and removing a passkey ask for Face ID', (t) async {
    gateway.passkeyList = [
      Passkey(
        id: 'pk1',
        friendlyName: 'iCloud Keychain',
        createdAt: DateTime.utc(2026, 11, 1),
      ),
    ];
    await pump(t, passkeys: true);

    await t.tap(find.byKey(const Key('addPasskeyTile')));
    await t.pumpAndSettle();
    expect(gateway.calls, contains('registerPasskey'));

    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    expect(gateway.calls, contains('deletePasskey:pk1'));
    expect(lock.reasons, ['Add a passkey', 'Remove a passkey']);
  });
}

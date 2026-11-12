import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/exceptions.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// How a sign-in ended. [cancelled] is the person closing the Apple sheet or
/// the passkey prompt: not an error, nothing to show.
enum SignInOutcome { signedIn, newAccount, cancelled }

/// What Apple hands back for one sign-in. Name fields are only filled the
/// first time a person authorises the app.
class AppleCredential {
  const AppleCredential({this.identityToken, this.givenName, this.familyName});
  final String? identityToken;
  final String? givenName;
  final String? familyName;
}

/// Shows Apple's sheet with the already-hashed nonce. Null when the person
/// cancelled.
typedef AppleCredentialFetcher = Future<AppleCredential?> Function(
  String hashedNonce,
);

/// The real Apple sheet (iOS). A cancel is null; anything else propagates.
Future<AppleCredential?> systemAppleCredential(String hashedNonce) async {
  try {
    final c = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );
    return AppleCredential(
      identityToken: c.identityToken,
      givenName: c.givenName,
      familyName: c.familyName,
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    rethrow;
  }
}

/// A sign-in step failed in a way the person can retry. [message] is safe to
/// show: it never carries server text, an email address or journal content.
class AccountAuthException implements Exception {
  const AccountAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One signed-in device, from `list_my_sessions`. The Dart client sends a
/// generic user agent, so the app shows dates and a coarse kind, not a name.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.createdAt,
    required this.lastActiveAt,
    required this.userAgent,
    required this.isCurrent,
  });

  factory DeviceSession.fromJson(Map<String, dynamic> json) => DeviceSession(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
        lastActiveAt: DateTime.parse(
          (json['last_active_at'] ?? json['created_at']) as String,
        ).toLocal(),
        userAgent: json['user_agent'] as String?,
        isCurrent: json['is_current'] == true,
      );

  final String id;
  final DateTime createdAt;
  final DateTime lastActiveAt;
  final String? userAgent;
  final bool isCurrent;

  /// "Web browser" for a browser user agent, else the app.
  String get kind =>
      (userAgent ?? '').contains('Mozilla') ? 'Web browser' : 'Lumen app';
}

/// The slice of Supabase Auth this feature uses, so the flow can be tested
/// without a network (see test/account_auth_service_test.dart).
abstract interface class AuthGateway {
  String generateRawNonce();
  Future<AuthResponse> signInWithAppleToken(String idToken, String nonce);
  Future<AuthResponse> linkAppleToken(String idToken, String nonce);
  Future<void> setUserName(Map<String, dynamic> data);
  Future<List<UserIdentity>> identities();

  /// Null when the person cancelled the passkey prompt.
  Future<AuthResponse?> signInWithPasskey();
  Future<bool> registerPasskey();
  Future<List<Passkey>> listPasskeys();
  Future<void> deletePasskey(String id);

  Future<Object?> rpc(String function, [Map<String, dynamic>? params]);
}

class SupabaseAuthGateway implements AuthGateway {
  SupabaseAuthGateway(this._client, {PasskeyAuthenticator? authenticator})
      : _authenticator = authenticator ?? PasskeyAuthenticator();

  final SupabaseClient _client;
  final PasskeyAuthenticator _authenticator;

  @override
  String generateRawNonce() => _client.auth.generateRawNonce();

  @override
  Future<AuthResponse> signInWithAppleToken(String idToken, String nonce) =>
      _client.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: nonce,
      );

  @override
  Future<AuthResponse> linkAppleToken(String idToken, String nonce) =>
      _client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: nonce,
      );

  @override
  Future<void> setUserName(Map<String, dynamic> data) async {
    await _client.auth.updateUser(UserAttributes(data: data));
  }

  @override
  Future<List<UserIdentity>> identities() => _client.auth.getUserIdentities();

  // The passkey API is experimental in supabase_flutter 2.15+.
  // ignore_for_file: experimental_member_use
  @override
  Future<AuthResponse?> signInWithPasskey() async {
    try {
      return await _client.auth.signInWithPasskey(_authenticator);
    } on PasskeyAuthCancelledException {
      return null;
    }
  }

  @override
  Future<bool> registerPasskey() async {
    try {
      await _client.auth.registerPasskey(_authenticator);
      return true;
    } on PasskeyAuthCancelledException {
      return false;
    }
  }

  @override
  Future<List<Passkey>> listPasskeys() => _client.auth.passkey.list();

  @override
  Future<void> deletePasskey(String id) =>
      _client.auth.passkey.delete(passkeyId: id);

  @override
  Future<Object?> rpc(String function, [Map<String, dynamic>? params]) =>
      _client.rpc(function, params: params);
}

/// Sign in with Apple, passkeys, and the signed-in device list (LM-58).
///
/// Nothing here logs a token, an email or an error body.
class AccountAuthService {
  AccountAuthService(
    this._gateway, {
    AppleCredentialFetcher appleCredential = systemAppleCredential,
    DateTime Function() now = DateTime.now,
  })  : _apple = appleCredential,
        _now = now;

  final AuthGateway _gateway;
  final AppleCredentialFetcher _apple;
  final DateTime Function() _now;

  /// Apple wants the SHA-256 of the nonce in its request; Supabase wants the
  /// raw one with the token, and compares the two.
  @visibleForTesting
  static String hashNonce(String raw) =>
      sha256.convert(utf8.encode(raw)).toString();

  /// The native flow: Apple sheet, then `signInWithIdToken`. A hidden email
  /// (a privaterelay address) works the same: it is the account's email.
  Future<SignInOutcome> signInWithApple() async {
    final rawNonce = _gateway.generateRawNonce();
    final credential = await _apple(hashNonce(rawNonce));
    if (credential == null) return SignInOutcome.cancelled;
    final token = credential.identityToken;
    if (token == null || token.isEmpty) {
      throw const AccountAuthException('Apple did not return a sign-in.');
    }
    final response = await _gateway.signInWithAppleToken(token, rawNonce);
    await _saveName(credential);
    return _isNewAccount(response.user)
        ? SignInOutcome.newAccount
        : SignInOutcome.signedIn;
  }

  /// Adds Apple to the signed-in account, so it is not split in two. True
  /// when linked, false when the person cancelled. Needs "Allow manual
  /// linking" on in the Supabase dashboard.
  Future<bool> linkApple() async {
    final rawNonce = _gateway.generateRawNonce();
    final credential = await _apple(hashNonce(rawNonce));
    if (credential == null) return false;
    final token = credential.identityToken;
    if (token == null || token.isEmpty) {
      throw const AccountAuthException('Apple did not return a sign-in.');
    }
    await _gateway.linkAppleToken(token, rawNonce);
    return true;
  }

  Future<bool> hasAppleLinked() async => (await _gateway.identities())
      .any((identity) => identity.provider == 'apple');

  Future<SignInOutcome> signInWithPasskey() async {
    final response = await _gateway.signInWithPasskey();
    if (response == null) return SignInOutcome.cancelled;
    return _isNewAccount(response.user)
        ? SignInOutcome.newAccount
        : SignInOutcome.signedIn;
  }

  /// Adds a passkey to the signed-in account. False when cancelled.
  Future<bool> addPasskey() => _gateway.registerPasskey();

  Future<List<Passkey>> passkeys() => _gateway.listPasskeys();

  Future<void> removePasskey(String id) => _gateway.deletePasskey(id);

  Future<List<DeviceSession>> devices() async {
    final rows = await _gateway.rpc('list_my_sessions');
    return (rows as List)
        .map((row) => DeviceSession.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  /// Signs one other device out: its refresh token is deleted on the server
  /// (its current access token works until it expires). False when there was
  /// nothing of yours to revoke, or it is this device.
  Future<bool> signOutDevice(String sessionId) async {
    final result =
        await _gateway.rpc('revoke_my_session', {'p_session_id': sessionId});
    return result == true;
  }

  Future<void> _saveName(AppleCredential c) async {
    final given = c.givenName?.trim();
    final family = c.familyName?.trim();
    final parts = [
      if (given != null && given.isNotEmpty) given,
      if (family != null && family.isNotEmpty) family,
    ];
    if (parts.isEmpty) return;
    try {
      // Apple sends the name once; the greeting reads full_name.
      await _gateway.setUserName({
        'full_name': parts.join(' '),
        if (given != null && given.isNotEmpty) 'given_name': given,
        if (family != null && family.isNotEmpty) 'family_name': family,
      });
    } catch (_) {
      // The name is a nicety; the sign-in already worked.
    }
  }

  /// A brand-new user: created and signed in within seconds of each other,
  /// and just now. An existing account (including one Apple auto-linked by
  /// email) was created earlier.
  bool _isNewAccount(User? user) {
    final created = DateTime.tryParse(user?.createdAt ?? '');
    if (created == null) return false;
    final last = DateTime.tryParse(user?.lastSignInAt ?? '') ?? created;
    return last.difference(created).abs() < const Duration(seconds: 10) &&
        _now().difference(created).abs() < const Duration(minutes: 2);
  }
}

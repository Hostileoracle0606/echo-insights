import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_auth_service.dart';

/// How "Delete my account" ended. [deletedAppleNotRevoked]: the account is
/// gone but Apple still lists Lumen, so the person is told how to remove it.
/// [cancelled]: the person closed Apple's sheet; nothing was deleted.
enum DeleteOutcome { deleted, deletedAppleNotRevoked, cancelled }

/// The calls around the `delete-account` edge function (LM-114/115), so the
/// flow can be tested without a network.
abstract interface class DeleteAccountGateway {
  /// A new access token: the function refuses one older than 5 minutes.
  Future<void> refreshSession();

  Future<({bool deleted, bool? appleRevoked})> call({
    String? appleAuthorizationCode,
  });

  /// Ends this phone's session only.
  Future<void> signOutLocal();
}

class SupabaseDeleteAccountGateway implements DeleteAccountGateway {
  SupabaseDeleteAccountGateway(this._client);

  final SupabaseClient _client;
  String? _accessToken;

  @override
  Future<void> refreshSession() async {
    final session = (await _client.auth.refreshSession()).session;
    final token = session?.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('No session to refresh.');
    }
    _accessToken = token;
  }

  @override
  Future<({bool deleted, bool? appleRevoked})> call({
    String? appleAuthorizationCode,
  }) async {
    final token = _accessToken;
    if (token == null) throw StateError('Refresh the session first.');
    // The token is passed explicitly: the functions client picks up a
    // refreshed session through an auth event that may not have landed yet.
    final response = await _client.functions.invoke(
      'delete-account',
      headers: {'Authorization': 'Bearer $token'},
      body: {
        if (appleAuthorizationCode != null)
          'apple_authorization_code': appleAuthorizationCode,
      },
    );
    final data = response.data;
    if (data is! Map) return (deleted: false, appleRevoked: null);
    final revoked = data['apple_revoked'];
    return (
      deleted: data['deleted'] == true,
      appleRevoked: revoked is bool ? revoked : null,
    );
  }

  @override
  Future<void> signOutLocal() =>
      _client.auth.signOut(scope: SignOutScope.local);
}

/// Deletes the signed-in account (LM-116). The caller has already asked for
/// Face ID and shown the confirmation; this runs Apple's sheet again for
/// Apple accounts (a fresh single-use code, right before the call), refreshes
/// the session, calls the function, and signs this phone out once the server
/// says the account is gone. The caller then erases what is left on the
/// phone. Nothing here logs or surfaces a token, a code or server text.
class AccountDeletionService {
  AccountDeletionService({
    required AccountAuthService auth,
    required DeleteAccountGateway gateway,
  })  : _auth = auth,
        _gateway = gateway;

  final AccountAuthService _auth;
  final DeleteAccountGateway _gateway;

  static const failure = AccountAuthException(
    'Could not delete your account. Check your connection and try again.',
  );

  /// Throws [failure] when the account was not deleted; the person is still
  /// signed in and nothing on the phone has been touched.
  Future<DeleteOutcome> deleteAccount() async {
    final ({bool deleted, bool? appleRevoked}) result;
    try {
      String? code;
      if (await _auth.hasAppleLinked()) {
        final credential = await _auth.reauthenticateWithApple();
        if (credential == null) return DeleteOutcome.cancelled;
        // A missing code still deletes: the server reports Apple as not
        // revoked and the person is told how to remove Lumen themselves.
        final c = credential.authorizationCode;
        code = (c == null || c.isEmpty) ? null : c;
      }
      await _gateway.refreshSession();
      result = await _gateway.call(appleAuthorizationCode: code);
    } catch (_) {
      // Never pass the error on: it can carry a token or server text.
      throw failure;
    }
    if (!result.deleted) throw failure;

    try {
      await _gateway.signOutLocal();
    } catch (_) {
      // The account is already gone; its session cannot be used again.
    }
    return result.appleRevoked == false
        ? DeleteOutcome.deletedAppleNotRevoked
        : DeleteOutcome.deleted;
  }
}

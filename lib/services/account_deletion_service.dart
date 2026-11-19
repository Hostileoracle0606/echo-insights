import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'account_auth_service.dart';
import 'deletion_pending_store.dart';

/// How "Delete my account" ended. [deletedAppleNotRevoked]: the account is
/// gone but Apple still lists Lumen, so the person is told how to remove it.
/// [cancelled]: the person closed Apple's sheet; nothing was deleted.
enum DeleteOutcome { deleted, deletedAppleNotRevoked, cancelled }

/// The server's answer: [queued] when the deletion is queued (new, or
/// [alreadyQueued] under the same request id). [appleRevoked] is null when
/// there was no Apple account or the request was already queued.
typedef DeleteReply = ({bool queued, bool alreadyQueued, bool? appleRevoked});

/// The session cannot be refreshed or the function refuses it (401): the
/// account is gone or signed out. Carries no server text.
class DeletionSessionGone implements Exception {
  const DeletionSessionGone();
}

/// The calls around the `delete-account` edge function (LM-114/115), so the
/// flow can be tested without a network.
abstract interface class DeleteAccountGateway {
  /// A new access token: the function refuses one older than 5 minutes.
  /// Throws [DeletionSessionGone] when there is no session or the refresh
  /// token is refused; a network error is thrown as is.
  Future<void> refreshSession();

  /// Queues the deletion under [requestId] (the same id on every resend).
  /// Throws [DeletionSessionGone] on a 401.
  Future<DeleteReply> call({
    required String requestId,
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
    final Session? session;
    try {
      session = (await _client.auth.refreshSession()).session;
    } on AuthRetryableFetchException {
      rethrow; // The network, not the session.
    } on AuthException {
      throw const DeletionSessionGone();
    }
    final token = session?.accessToken;
    if (token == null || token.isEmpty) throw const DeletionSessionGone();
    _accessToken = token;
  }

  @override
  Future<DeleteReply> call({
    required String requestId,
    String? appleAuthorizationCode,
  }) async {
    final token = _accessToken;
    if (token == null) throw StateError('Refresh the session first.');
    // The token is passed explicitly: the functions client picks up a
    // refreshed session through an auth event that may not have landed yet.
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'delete-account',
        headers: {'Authorization': 'Bearer $token'},
        body: {
          'request_id': requestId,
          if (appleAuthorizationCode != null)
            'apple_authorization_code': appleAuthorizationCode,
        },
      );
    } on FunctionException catch (e) {
      // The status only: the body is server text and never passed on.
      if (e.status == 401) throw const DeletionSessionGone();
      rethrow;
    }
    final data = response.data;
    if (data is! Map) {
      return (queued: false, alreadyQueued: false, appleRevoked: null);
    }
    final revoked = data['apple_revoked'];
    return (
      queued: data['queued'] == true,
      alreadyQueued: data['already_queued'] == true,
      appleRevoked: revoked is bool ? revoked : null,
    );
  }

  @override
  Future<void> signOutLocal() =>
      _client.auth.signOut(scope: SignOutScope.local);
}

/// Deletes the signed-in account (LM-116). The caller has already asked for
/// Face ID and shown the confirmation; this runs Apple's sheet again for
/// Apple accounts (a fresh single-use code, right before the call), writes
/// the "deletion pending" marker, refreshes the session and asks the server
/// to queue the deletion. Only once the server answers "queued" (new or
/// already) is the marker cleared and this phone signed out; the caller then
/// erases what is left on the phone. A lost reply keeps the marker, and the
/// same request id is resent on the next try or the next launch
/// ([resumePending]). Nothing here logs or surfaces a token, a code, the
/// request id or server text.
class AccountDeletionService {
  AccountDeletionService({
    required AccountAuthService auth,
    required DeleteAccountGateway gateway,
    required DeletionPendingStore store,
    String Function()? newRequestId,
    Duration timeout = const Duration(seconds: 45),
  })  : _auth = auth,
        _gateway = gateway,
        _store = store,
        _newRequestId = newRequestId ?? (() => const Uuid().v4()),
        _timeout = timeout;

  final AccountAuthService _auth;
  final DeleteAccountGateway _gateway;
  final DeletionPendingStore _store;
  final String Function() _newRequestId;

  /// For each network step, not Apple's sheet (the person may take their
  /// time there). A hung request ends as [failure] instead of a spinner.
  final Duration _timeout;

  static const failure = AccountAuthException(
    'Could not delete your account. Check your connection and try again.',
  );

  /// Throws [failure] when the server did not answer "queued"; the person is
  /// still signed in, nothing on the phone has been touched, and the marker
  /// is kept so a retry resends the same request id.
  Future<DeleteOutcome> deleteAccount() async {
    final DeleteReply result;
    try {
      String? code;
      if (await _auth.hasAppleLinked().timeout(_timeout)) {
        final credential = await _auth.reauthenticateWithApple();
        if (credential == null) return DeleteOutcome.cancelled;
        // A missing code still deletes: the server reports Apple as not
        // revoked and the person is told how to remove Lumen themselves.
        final c = credential.authorizationCode;
        code = (c == null || c.isEmpty) ? null : c;
      }
      // One id for the whole deletion: a retry after a lost reply resends
      // it, and the server answers "already queued".
      var requestId = await _store.read().timeout(_timeout);
      if (requestId == null) {
        requestId = _newRequestId();
        await _store.write(requestId).timeout(_timeout);
      }
      await _gateway.refreshSession().timeout(_timeout);
      result = await _gateway
          .call(requestId: requestId, appleAuthorizationCode: code)
          .timeout(_timeout);
    } catch (_) {
      // Never pass the error on: it can carry a token or server text.
      throw failure;
    }
    if (!result.queued) throw failure;

    await _finish();
    return result.appleRevoked == false
        ? DeleteOutcome.deletedAppleNotRevoked
        : DeleteOutcome.deleted;
  }

  /// At launch: resends a deletion whose "queued" answer never arrived.
  /// Null when there is nothing pending, or the server could not be reached
  /// (the marker is kept for the next launch). Once the server answers
  /// "queued", or the session turns out to be gone (the account was already
  /// deleted, or the person asked for it and can no longer reach it), the
  /// marker is cleared, this phone is signed out and the outcome returned so
  /// the caller wipes the phone. The resend carries no Apple code (it is
  /// single-use). Never throws.
  Future<DeleteOutcome?> resumePending() async {
    final String? requestId;
    try {
      requestId = await _store.read().timeout(_timeout);
    } catch (_) {
      return null;
    }
    if (requestId == null) return null;

    final DeleteReply result;
    try {
      await _gateway.refreshSession().timeout(_timeout);
      result =
          await _gateway.call(requestId: requestId).timeout(_timeout);
    } on DeletionSessionGone {
      await _finish();
      return DeleteOutcome.deleted;
    } catch (_) {
      return null;
    }
    if (!result.queued) return null;

    await _finish();
    return result.appleRevoked == false
        ? DeleteOutcome.deletedAppleNotRevoked
        : DeleteOutcome.deleted;
  }

  /// The deletion is queued (or the account is out of reach): the marker
  /// goes, then the session.
  Future<void> _finish() async {
    try {
      await _store.clear();
    } catch (_) {
      // A marker left behind is resent next launch and finds the session
      // gone: the same wipe, nothing more.
    }
    try {
      await _gateway.signOutLocal();
    } catch (_) {
      // The account is going; its session cannot be used again.
    }
  }
}

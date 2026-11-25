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
/// there was no Apple account, and false when revocation is unconfirmed.
typedef DeleteReply = ({bool queued, bool alreadyQueued, bool? appleRevoked});

/// The session cannot be refreshed because it, or its user, no longer
/// exists: no session on the phone, or the auth server answers
/// `refresh_token_not_found`, `session_not_found` or `user_not_found`. Only
/// a refresh can prove this; anything else is transient. Carries no server
/// text.
class DeletionSessionGone implements Exception {
  const DeletionSessionGone();
}

/// Auth error codes on a refresh that mean the session or user is gone.
/// (`bad_jwt` is not here: the refresh grant sends no JWT.)
const _sessionGoneCodes = {
  'refresh_token_not_found',
  'session_not_found',
  'user_not_found',
};

/// The calls around the `delete-account` edge function (LM-114/115), so the
/// flow can be tested without a network.
abstract interface class DeleteAccountGateway {
  String? get userId;

  /// A new access token: the function refuses one older than 5 minutes.
  /// Throws [DeletionSessionGone] only when the session or user is proven
  /// gone; any other failure (network, rate limit, 5xx) is thrown as is.
  Future<void> refreshSession({String? expectedUserId});

  /// Queues the deletion under [requestId] (the same id on every resend).
  /// Any failure here (a 401 included) is transient: it never proves the
  /// session is gone, since the refresh just before it worked.
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
  String? get userId => _client.auth.currentUser?.id;

  @override
  Future<void> refreshSession({String? expectedUserId}) async {
    _accessToken = null;
    final Session? session;
    try {
      session = (await _client.auth.refreshSession()).session;
    } on AuthSessionMissingException {
      throw const DeletionSessionGone();
    } on AuthApiException catch (e) {
      if (_sessionGoneCodes.contains(e.code)) {
        throw const DeletionSessionGone();
      }
      rethrow; // A rate limit or another refusal: try again later.
    }
    final token = session?.accessToken;
    if (token == null || token.isEmpty) throw const DeletionSessionGone();
    if (expectedUserId != null && session?.user.id != expectedUserId) {
      throw StateError('The account changed during deletion.');
    }
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
    // A non-2xx answer throws (the caller never passes the error on).
    final response = await _client.functions.invoke(
      'delete-account',
      headers: {'Authorization': 'Bearer $token'},
      body: {
        'request_id': requestId,
        if (appleAuthorizationCode != null)
          'apple_authorization_code': appleAuthorizationCode,
      },
    );
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
/// already) does this phone start cleanup. The marker survives until cleanup
/// finishes, then this phone signs out. A lost reply keeps the marker, and the
/// same request id is resent on the next try or the next launch
/// ([resumePending]). Nothing here logs or surfaces a token, a code, the
/// request id or server text.
class AccountDeletionService {
  AccountDeletionService({
    required AccountAuthService auth,
    required DeleteAccountGateway gateway,
    required DeletionPendingStore store,
    required Future<void> Function() cleanup,
    String Function()? newRequestId,
    Duration timeout = const Duration(seconds: 45),
  })  : _auth = auth,
        _gateway = gateway,
        _store = store,
        _cleanup = cleanup,
        _newRequestId = newRequestId ?? (() => const Uuid().v4()),
        _timeout = timeout;

  final AccountAuthService _auth;
  final DeleteAccountGateway _gateway;
  final DeletionPendingStore _store;
  final Future<void> Function() _cleanup;
  final String Function() _newRequestId;

  /// For each network step, not Apple's sheet (the person may take their
  /// time there). A hung request ends as [failure] instead of a spinner.
  final Duration _timeout;

  /// The request may have reached the server (the marker is set): the
  /// deletion may still go ahead, and the next launch resends it.
  static const failure = AccountAuthException(
    'We could not confirm that your account is being deleted. Check your '
    'connection and try again. If you close Lumen now, it will try again the '
    'next time you open it.',
  );

  /// Nothing was sent and no marker is set: nothing will happen later.
  static const notStarted = AccountAuthException(
    'Could not delete your account. Check your connection and try again.',
  );

  static const cleanupPending = AccountAuthException(
    'Your deletion request was received. Close and reopen Lumen to finish '
    'removing account data from this phone.',
  );

  /// Throws [failure] when the server did not answer "queued" (the marker is
  /// kept, so a retry or the next launch resends the same request id), or
  /// [notStarted] when it failed before any marker existed. Either way the
  /// person is still signed in and nothing on the phone has been touched.
  Future<DeleteOutcome> deleteAccount() async {
    final userId = _gateway.userId;
    if (userId == null) throw notStarted;
    final DeleteReply result;
    var markerSet = false;
    try {
      String? code;
      final isApple = await _auth.hasAppleLinked().timeout(_timeout);
      if (isApple) {
        final credential = await _auth.reauthenticateWithApple();
        if (credential == null) return DeleteOutcome.cancelled;
        // A missing code still deletes: the server reports Apple as not
        // revoked and the person is told how to remove Lumen themselves.
        final c = credential.authorizationCode;
        code = (c == null || c.isEmpty) ? null : c;
      }
      // One id for the whole deletion: a retry after a lost reply resends
      // it, and the server answers "already queued".
      var request = await _store.read().timeout(_timeout);
      if (request == null || request.userId != userId) {
        request =
            (userId: userId, requestId: _newRequestId(), isApple: isApple);
        await _store.write(request).timeout(_timeout);
      }
      markerSet = true;
      await _gateway.refreshSession(expectedUserId: userId).timeout(_timeout);
      result = await _gateway
          .call(requestId: request.requestId, appleAuthorizationCode: code)
          .timeout(_timeout);
    } catch (_) {
      // Never pass the error on: it can carry a token or server text.
      throw markerSet ? failure : notStarted;
    }
    if (!result.queued) throw failure;

    if (!await _finish(userId)) throw cleanupPending;
    return result.appleRevoked == false
        ? DeleteOutcome.deletedAppleNotRevoked
        : DeleteOutcome.deleted;
  }

  /// At launch: resends a deletion whose "queued" answer never arrived.
  /// Null when there is nothing pending, or the server could not be reached
  /// (the marker is kept for the next launch). Once the server answers
  /// "queued", or the refresh proves the session is gone (the account was
  /// already deleted, or the person asked for it and can no longer reach it),
  /// cleanup finishes before the marker is cleared and the phone signs out.
  /// The resend carries no Apple code because it is single-use. Never throws.
  Future<DeleteOutcome?> resumePending() async {
    final PendingAccountDeletion? request;
    try {
      request = await _store.read().timeout(_timeout);
    } catch (_) {
      return null;
    }
    if (request == null || !_ownsSession(request.userId)) return null;

    try {
      await _gateway
          .refreshSession(expectedUserId: request.userId)
          .timeout(_timeout);
    } on DeletionSessionGone {
      if (!await _finish(request.userId)) return null;
      return request.isApple
          ? DeleteOutcome.deletedAppleNotRevoked
          : DeleteOutcome.deleted;
    } catch (_) {
      return null;
    }
    final DeleteReply result;
    try {
      result =
          await _gateway.call(requestId: request.requestId).timeout(_timeout);
    } catch (_) {
      // A 401 included: the refresh just worked, so it proves nothing.
      return null;
    }
    if (!result.queued) return null;

    if (!await _finish(request.userId)) return null;
    return result.appleRevoked == false
        ? DeleteOutcome.deletedAppleNotRevoked
        : DeleteOutcome.deleted;
  }

  bool _ownsSession(String userId) {
    final currentUser = _gateway.userId;
    return currentUser == null || currentUser == userId;
  }

  /// Keep the marker while cleanup runs so an interrupted wipe is retried.
  Future<bool> _finish(String userId) async {
    if (!_ownsSession(userId)) return false;
    try {
      await _cleanup();
    } catch (_) {
      return false;
    }
    if (!_ownsSession(userId)) return false;
    try {
      await _store.clear();
    } catch (_) {
      // A marker left behind allows the same cleanup to run again on launch.
    }
    try {
      await _gateway.signOutLocal();
    } catch (_) {
      // The account is going; its session cannot be used again.
    }
    return true;
  }
}

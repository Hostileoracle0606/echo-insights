import 'dart:async';

import 'package:lumen/services/account_deletion_service.dart';

/// A stand-in for the `delete-account` function and the session calls around
/// it. Records the order of calls into [events] (shared with other fakes).
class FakeDeleteAccountGateway implements DeleteAccountGateway {
  FakeDeleteAccountGateway({List<String>? events}) : events = events ?? [];

  final List<String> events;
  final sentCodes = <String?>[];
  final sentRequestIds = <String>[];

  DeleteReply result = (queued: true, alreadyQueued: false, appleRevoked: null);

  /// When set, used instead of [result] for each call in turn (the last one
  /// repeats): e.g. a lost reply followed by "already queued".
  List<Object>? replies;
  Object? refreshError;
  Object? callError;
  Object? signOutError;

  /// When set, `call` waits for it (a slow or hung network).
  Future<void>? callGate;

  @override
  Future<void> refreshSession() async {
    events.add('refreshSession');
    if (refreshError != null) throw refreshError!;
  }

  @override
  Future<DeleteReply> call({
    required String requestId,
    String? appleAuthorizationCode,
  }) async {
    events.add('call');
    sentRequestIds.add(requestId);
    sentCodes.add(appleAuthorizationCode);
    if (callGate != null) await callGate;
    if (callError != null) throw callError!;
    final queue = replies;
    if (queue != null && queue.isNotEmpty) {
      final next = queue.length > 1 ? queue.removeAt(0) : queue.first;
      if (next is DeleteReply) return next;
      throw next;
    }
    return result;
  }

  @override
  Future<void> signOutLocal() async {
    events.add('signOutLocal');
    if (signOutError != null) throw signOutError!;
  }
}

import 'dart:async';

import 'package:lumen/services/account_deletion_service.dart';

/// A stand-in for the `delete-account` function and the session calls around
/// it. Records the order of calls into [events] (shared with other fakes).
class FakeDeleteAccountGateway implements DeleteAccountGateway {
  FakeDeleteAccountGateway({List<String>? events}) : events = events ?? [];

  final List<String> events;
  final sentCodes = <String?>[];

  ({bool deleted, bool? appleRevoked}) result =
      (deleted: true, appleRevoked: null);
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
  Future<({bool deleted, bool? appleRevoked})> call({
    String? appleAuthorizationCode,
  }) async {
    events.add('call');
    sentCodes.add(appleAuthorizationCode);
    if (callGate != null) await callGate;
    if (callError != null) throw callError!;
    return result;
  }

  @override
  Future<void> signOutLocal() async {
    events.add('signOutLocal');
    if (signOutError != null) throw signOutError!;
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_brief.dart';
import '../services/session_brief_service.dart';
import 'supabase_provider.dart';

/// What the opening choice reads: the last sign-in lookup, and whether this
/// app run created the account. Starting a session never waits on it.
class OpeningPrep {
  OpeningPrep(this._service);

  final SessionBriefService _service;
  SessionOpeningState? _current;
  bool _knownNewAccount = false;

  SessionOpeningState? get current => _current;
  bool get knownNewAccount => _knownNewAccount;

  /// Reloads the brief state. Never throws: a failure is logged and the
  /// previous state stays.
  Future<void> refresh() async {
    try {
      _current = await _service.load();
    } catch (error, stack) {
      debugPrint('OpeningPrep.refresh failed: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 5);
    }
  }

  void markNewAccount() => _knownNewAccount = true;

  /// The brief just played: this device sees it as played before the next
  /// refresh lands.
  void markPlayedLocally() {
    final state = _current;
    final brief = state?.brief;
    if (state == null || brief == null) return;
    _current = SessionOpeningState(
      returning: state.returning,
      brief: brief.copyWith(playedAt: DateTime.now()),
    );
  }
}

final openingPrepProvider = Provider<OpeningPrep>((ref) {
  return OpeningPrep(ref.watch(sessionBriefServiceProvider));
});

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

  /// Bumped by every [refresh] and by [clear]; a load only lands if it is
  /// still the latest when it returns.
  int _generation = 0;

  /// The brief (by createdAt) this device has played. A refresh that was
  /// issued before the server heard about it must not bring it back.
  DateTime? _locallyPlayed;

  SessionOpeningState? get current => _current;
  bool get knownNewAccount => _knownNewAccount;

  /// Reloads the brief state. Never throws: a failure is logged and the
  /// previous state stays. A call superseded by a newer one (or by
  /// [clear]) is discarded.
  Future<void> refresh() async {
    final generation = ++_generation;
    try {
      final loaded = await _service.load();
      if (generation != _generation) return;
      _current = _keepLocalPlayed(loaded);
    } catch (error) {
      // debugPrintStack can itself throw on async traces; keep this plain.
      debugPrint('OpeningPrep.refresh failed: $error');
    }
  }

  SessionOpeningState _keepLocalPlayed(SessionOpeningState loaded) {
    final brief = loaded.brief;
    final played = _locallyPlayed;
    if (brief == null ||
        played == null ||
        brief.playedAt != null ||
        !brief.createdAt.isAtSameMomentAs(played)) {
      return loaded;
    }
    return SessionOpeningState(
      returning: loaded.returning,
      brief: brief.copyWith(playedAt: DateTime.now()),
    );
  }

  /// This app run created the account (the first session gets the intro).
  void markNewAccount() => _knownNewAccount = true;

  /// The intro clip played: later sessions are no longer a first one.
  void markIntroPlayed() => _knownNewAccount = false;

  /// The brief just played: this device sees it as played before the next
  /// refresh lands.
  void markPlayedLocally() {
    final state = _current;
    final brief = state?.brief;
    if (state == null || brief == null) return;
    _locallyPlayed = brief.createdAt;
    _current = SessionOpeningState(
      returning: state.returning,
      brief: brief.copyWith(playedAt: DateTime.now()),
    );
  }

  /// Sign-out: forget everything and drop loads still in flight, so the
  /// next account never sees this one's brief.
  void clear() {
    _generation++;
    _current = null;
    _locallyPlayed = null;
    _knownNewAccount = false;
  }
}

final openingPrepProvider = Provider<OpeningPrep>((ref) {
  return OpeningPrep(ref.watch(sessionBriefServiceProvider));
});

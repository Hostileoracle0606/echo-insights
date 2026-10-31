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

  /// Set by [markReturning]: this device knows the account has history, so
  /// a load that lands later (issued before the server saw it) cannot make
  /// it look new again. Cleared only by [clear].
  bool _knownReturning = false;

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
    final returning = loaded.returning || _knownReturning;
    if (brief == null ||
        played == null ||
        brief.playedAt != null ||
        !brief.createdAt.isAtSameMomentAs(played)) {
      if (returning == loaded.returning) return loaded;
      return SessionOpeningState(returning: returning, brief: brief);
    }
    return SessionOpeningState(
      returning: returning,
      brief: brief.copyWith(playedAt: DateTime.now()),
    );
  }

  /// This app run created the account (the first session gets the intro).
  void markNewAccount() => _knownNewAccount = true;

  /// The intro clip played: later sessions are no longer a first one.
  void markIntroPlayed() => _knownNewAccount = false;

  /// A session with something the user said just closed: the account is
  /// returning from now on, without waiting for the next [refresh] (which
  /// may be seconds away, or never come if the brief request fails). Keeps
  /// whatever brief is current; a later refresh can still replace it.
  void markReturning() {
    _knownReturning = true;
    _current = SessionOpeningState(returning: true, brief: _current?.brief);
  }

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
    _knownReturning = false;
  }
}

final openingPrepProvider = Provider<OpeningPrep>((ref) {
  return OpeningPrep(ref.watch(sessionBriefServiceProvider));
});

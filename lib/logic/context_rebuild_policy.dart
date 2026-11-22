/// When to rebuild a Gemini Live session from saved context instead of
/// letting Gemini compress its window (EC-01, docs/externalized-context-tickets.md).
///
/// A rebuild replaces the connection, so it happens only at a pause: never
/// while anyone has the floor, and never off the record, because rebuilt
/// context comes only from saved turns.
library;

/// Why a rebuild is due.
enum RebuildReason { turnBudget, maxAge }

class ContextRebuildConfig {
  /// Completed turns since the last rebuild. At most [resumeContext]'s 20, so
  /// every turn since the last rebuild is still replayed after it.
  final int maxTurns;

  /// With compression off, Gemini audio sessions end at ~15 minutes, so the
  /// age bound must rebuild well before that.
  final Duration maxAge;

  /// A turn budget spent soon after a rebuild waits this long, so rebuilds
  /// never come in quick succession.
  final Duration minInterval;

  const ContextRebuildConfig({
    this.maxTurns = 20,
    this.maxAge = const Duration(minutes: 10),
    this.minInterval = const Duration(minutes: 2),
  });

  /// [maxTurns] from a `--dart-define` string; invalid values keep the default.
  factory ContextRebuildConfig.fromDefines({String maxTurns = ''}) {
    final turns = int.tryParse(maxTurns.trim());
    const fallback = ContextRebuildConfig();
    return ContextRebuildConfig(
      maxTurns: turns != null && turns > 0 ? turns : fallback.maxTurns,
    );
  }
}

/// Who has the floor and what the session is doing, at the moment of a check.
class FloorState {
  final bool live;
  final bool agentSpeaking;
  final bool userSpeaking;
  final bool awaitingReply;
  final bool reconnecting;
  final bool offTheRecord;

  const FloorState({
    required this.live,
    required this.agentSpeaking,
    required this.userSpeaking,
    required this.awaitingReply,
    required this.reconnecting,
    required this.offTheRecord,
  });

  bool get isPause =>
      live &&
      !agentSpeaking &&
      !userSpeaking &&
      !awaitingReply &&
      !reconnecting &&
      !offTheRecord;

  FloorState copyWith({
    bool? live,
    bool? agentSpeaking,
    bool? userSpeaking,
    bool? awaitingReply,
    bool? reconnecting,
    bool? offTheRecord,
  }) =>
      FloorState(
        live: live ?? this.live,
        agentSpeaking: agentSpeaking ?? this.agentSpeaking,
        userSpeaking: userSpeaking ?? this.userSpeaking,
        awaitingReply: awaitingReply ?? this.awaitingReply,
        reconnecting: reconnecting ?? this.reconnecting,
        offTheRecord: offTheRecord ?? this.offTheRecord,
      );
}

class ContextRebuildPolicy {
  final ContextRebuildConfig config;
  DateTime _since;
  bool _rebuiltOnce = false;
  int _turns = 0;

  ContextRebuildPolicy(this.config, {required DateTime startedAt})
      : _since = startedAt;

  int get turnsSinceRebuild => _turns;
  DateTime get since => _since;

  void turnCompleted() => _turns++;

  /// The reason a rebuild is due now, or null to keep the session.
  RebuildReason? check(DateTime now, FloorState floor) {
    if (!floor.isPause) return null;
    final age = now.difference(_since);
    if (age >= config.maxAge) return RebuildReason.maxAge;
    if (_turns < config.maxTurns) return null;
    if (_rebuiltOnce && age < config.minInterval) return null;
    return RebuildReason.turnBudget;
  }

  /// The session was rebuilt at [now]: the budget and age start again.
  void rebuilt(DateTime now) {
    _since = now;
    _turns = 0;
    _rebuiltOnce = true;
  }
}

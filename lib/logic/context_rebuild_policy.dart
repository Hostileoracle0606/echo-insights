/// When to rebuild a Gemini Live session from saved context instead of
/// letting Gemini compress its window (EC-01, docs/externalized-context-tickets.md).
///
/// A rebuild replaces the connection, so it happens only at a pause: never
/// while anyone has the floor, and never off the record, because rebuilt
/// context comes only from saved turns.
library;

/// Why a rebuild is due.
enum RebuildReason { turnBudget, tokenBudget, maxAge, correction }

class ContextRebuildConfig {
  /// Estimated tokens of conversation since the last rebuild (EC-05): the
  /// window is rebuilt before it grows past this, so it never needs
  /// compressing.
  final int maxTokens;

  /// Completed turns since the last rebuild. Off unless set: an override
  /// for testing a rebuild quickly (CONTEXT_REBUILD_MAX_TURNS).
  final int? maxTurns;

  /// With compression off, Gemini audio sessions end at ~15 minutes, so the
  /// age bound must rebuild well before that.
  final Duration maxAge;

  /// A budget spent soon after a rebuild waits this long, so rebuilds never
  /// come in quick succession.
  final Duration minInterval;

  const ContextRebuildConfig({
    this.maxTokens = 6000,
    this.maxTurns,
    this.maxAge = const Duration(minutes: 10),
    this.minInterval = const Duration(minutes: 2),
  });

  /// From `--dart-define` strings; invalid values keep the defaults.
  factory ContextRebuildConfig.fromDefines({
    String maxTurns = '',
    String maxTokens = '',
  }) {
    final turns = int.tryParse(maxTurns.trim());
    final tokens = int.tryParse(maxTokens.trim());
    const fallback = ContextRebuildConfig();
    return ContextRebuildConfig(
      maxTurns: turns != null && turns > 0 ? turns : null,
      maxTokens: tokens != null && tokens > 0 ? tokens : fallback.maxTokens,
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
  int _tokens = 0;
  int? _baseline;
  RebuildReason? _requested;

  ContextRebuildPolicy(this.config, {required DateTime startedAt})
      : _since = startedAt;

  int get turnsSinceRebuild => _turns;
  int get tokensSinceRebuild => _tokens;
  DateTime get since => _since;

  /// A turn ended; [tokens] estimates what it added to the window.
  void turnCompleted({int tokens = 0}) {
    _turns++;
    _tokens += tokens < 0 ? 0 : tokens;
  }

  /// Gemini reported the window's size ([promptTokens]). The first report
  /// after a (re)build is the baseline (system instruction and seed
  /// context); growth past it is what the budget counts. Spoken audio costs
  /// far more than its transcript, so a report outweighs the estimate.
  void observedWindow(int promptTokens) {
    if (promptTokens <= 0) return;
    final baseline = _baseline ??= promptTokens;
    final grown = promptTokens - baseline;
    if (grown > _tokens) _tokens = grown;
  }

  /// Rebuild at the next pause whatever the budgets say: a confirmed
  /// correction must not stay in the window in its old form (EC-07).
  void request(RebuildReason reason) => _requested = reason;

  /// The reason a rebuild is due now, or null to keep the session.
  RebuildReason? check(DateTime now, FloorState floor) {
    if (!floor.isPause) return null;
    final age = now.difference(_since);
    if (age >= config.maxAge) return RebuildReason.maxAge;
    final requested = _requested;
    if (requested != null) return requested;
    final RebuildReason? due = _tokens >= config.maxTokens
        ? RebuildReason.tokenBudget
        : config.maxTurns != null && _turns >= config.maxTurns!
            ? RebuildReason.turnBudget
            : null;
    if (due == null) return null;
    if (_rebuiltOnce && age < config.minInterval) return null;
    return due;
  }

  /// The session was rebuilt at [now]: the budgets and age start again.
  void rebuilt(DateTime now) {
    _since = now;
    _turns = 0;
    _tokens = 0;
    _baseline = null;
    _requested = null;
    _rebuiltOnce = true;
  }
}

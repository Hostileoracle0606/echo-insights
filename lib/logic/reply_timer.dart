/// How long Lumen takes to answer each turn, as log lines: from the user's
/// turn (a typed send, or the last chunk of their transcript) to Gemini's
/// first tool call and to the first audio of the reply. A slow reply then
/// shows where it waited.
class ReplyTimer {
  DateTime? _turnAt;
  bool _typed = false;
  int? _toolMs;
  bool _replying = false;

  /// The user typed a turn, or more of their speech was transcribed. While
  /// Lumen is replying, late transcript chunks don't start a new turn.
  void userTurn(DateTime at, {bool typed = false}) {
    if (_replying) return;
    _turnAt = at;
    _typed = typed;
    _toolMs = null;
  }

  /// The line to log for a tool call, if it is the turn's first.
  String? toolCall(DateTime at) {
    final turnAt = _turnAt;
    if (turnAt == null || _toolMs != null) return null;
    _toolMs = at.difference(turnAt).inMilliseconds;
    return '$_kind → tool call +${_toolMs}ms';
  }

  /// The line to log for an audio chunk, if it starts the turn's reply.
  String? replyAudio(DateTime at) {
    final turnAt = _turnAt;
    if (turnAt == null || _replying) return null;
    _replying = true;
    _turnAt = null;
    final ms = at.difference(turnAt).inMilliseconds;
    final tool = _toolMs == null ? '' : ' (tool call at +${_toolMs}ms)';
    return '$_kind → reply audio +${ms}ms$tool';
  }

  /// The reply finished or was cut off.
  void replyEnded() {
    _replying = false;
  }

  String get _kind => _typed ? 'typed turn' : 'spoken turn';
}

/// Notices the app's main isolate freezing: a periodic tick that arrives
/// far later than scheduled means nothing ran in between, socket messages
/// included, so their logged times are late too.
class StallWatch {
  StallWatch({
    this.interval = const Duration(milliseconds: 250),
    this.threshold = const Duration(milliseconds: 750),
  });

  final Duration interval;
  final Duration threshold;

  /// [sinceLast] is the time since the previous tick; returns a log line
  /// when the tick was late by more than [threshold].
  String? tick(Duration sinceLast) {
    final late = sinceLast - interval;
    if (late <= threshold) return null;
    return 'app unresponsive for ~${late.inMilliseconds}ms';
  }
}

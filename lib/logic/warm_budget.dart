/// How many warm standby sessions an idle notebook may start.
///
/// Every warm-up costs a runtime call (a single-use Gemini credential) and
/// holds a Gemini Live connection, and a standby socket has to be replaced
/// before Gemini Live's ~10 minute connection limit. So an untouched notebook
/// gets the first warm plus two refreshes (~27 minutes of instant start),
/// then goes cold until the user interacts with the screen again.
class WarmBudget {
  WarmBudget({this.maxWarms = 3}) : _remaining = maxWarms;

  /// Replace a standby socket this long after it connected — under Gemini
  /// Live's ~10 minute connection limit, with margin for the reconnect.
  static const refreshAfter = Duration(minutes: 9);

  final int maxWarms;
  int _remaining;

  bool get exhausted => _remaining <= 0;

  /// Claims one warm-up. False once the budget is spent.
  bool tryConsume() {
    if (_remaining <= 0) return false;
    _remaining -= 1;
    return true;
  }

  /// The user is here: allow a fresh round of warm-ups.
  void refill() => _remaining = maxWarms;
}

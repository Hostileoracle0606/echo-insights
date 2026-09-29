import 'dart:async';
import 'dart:math' as math;

import '../logic/voice_log.dart';
import 'notebook_runtime_service.dart';

enum LiveCredentialsPhase { none, fetching, held }

/// Holds one Gemini Live token for the signed-in user, so tapping the mic
/// never waits on the runtime (plan: Flow 1).
///
/// Fetched at sign-in over HTTP only (no connection), refreshed shortly
/// before its start window lapses, and handed out once by [take], which
/// then fetches the next one. Failures back off quietly; there is never a
/// user-facing error from here — [take] returns null and the caller falls
/// back to the notebook route. After [idleLimit] without activity the
/// refreshes stop; the next [noteActivity] or [take] fetches again.
class LiveCredentials {
  LiveCredentials({
    required Future<LiveSessionOutcome> Function() fetch,
    DateTime Function()? now,
    this.refreshAt = 0.8,
    this.takeMargin = const Duration(seconds: 5),
    this.idleLimit = const Duration(minutes: 30),
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 1),
    this.fallbackWindow = const Duration(seconds: 60),
  })  : _fetch = fetch,
        _now = now ?? DateTime.now;

  /// Refresh once this fraction of the start window has passed (8 of 10 min).
  final double refreshAt;

  /// A token this close to the end of its start window is not handed out.
  final Duration takeMargin;
  final Duration idleLimit;
  final Duration minBackoff;
  final Duration maxBackoff;

  /// Start window assumed when the runtime doesn't report one.
  final Duration fallbackWindow;

  final Future<LiveSessionOutcome> Function() _fetch;
  final DateTime Function() _now;

  bool _active = false;
  bool _paused = false;
  bool _unsupported = false;
  int _generation = 0;
  _Held? _held;
  Future<bool>? _inFlight;
  Timer? _timer;
  Duration? _backoff;
  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);

  LiveCredentialsPhase get phase => _inFlight != null
      ? LiveCredentialsPhase.fetching
      : _usableHeld() != null
          ? LiveCredentialsPhase.held
          : LiveCredentialsPhase.none;

  /// The runtime has no user-scoped route (not deployed yet). Stays set
  /// until the next sign-in.
  bool get unsupported => _unsupported;

  /// Signed in: fetch the first token.
  void start() {
    if (_active) return;
    _active = true;
    _paused = false;
    _unsupported = false;
    _backoff = null;
    _lastActivity = _now();
    _ensureFetch();
  }

  /// Signed out: forget the token and anything in flight.
  void stop() {
    _active = false;
    _generation += 1;
    _held = null;
    _inFlight = null;
    _backoff = null;
    _cancelTimer();
  }

  /// App in the background: no refreshes (the token is kept if still valid).
  void pause() {
    _paused = true;
    _cancelTimer();
  }

  /// App back in the foreground.
  void resume() {
    _paused = false;
    noteActivity();
  }

  /// The user is here: refreshes continue, and a missing token is fetched.
  void noteActivity() {
    _lastActivity = _now();
    if (!_active || _paused) return;
    final held = _usableHeld();
    if (held == null) {
      // A pending retry keeps its back-off; otherwise fetch now.
      if (_timer == null) _ensureFetch();
    } else if (_timer == null) {
      _scheduleRefresh(held);
    }
  }

  /// Hands out a token that can still start a connection, then fetches the
  /// next one. Waits only for a fetch that is running or needed now; null
  /// when none can be had (signed out, unsupported, or the fetch failed).
  Future<LiveSessionReady?> take() async {
    _lastActivity = _now();
    // Three rounds: a concurrent taker may claim the token this fetch
    // produced, and then this caller waits for the refetch that follows.
    for (var attempt = 0; attempt < 3; attempt++) {
      final held = _usableHeld();
      if (held != null) {
        _held = null;
        _cancelTimer();
        vlog('credentials', 'token taken');
        if (_active && !_paused) _ensureFetch();
        return held.ready;
      }
      if (!_active || _unsupported) return null;
      if (!await _ensureFetch()) return null;
    }
    return null;
  }

  _Held? _usableHeld() {
    final held = _held;
    if (held == null) return null;
    if (!_now().add(takeMargin).isBefore(held.startBy)) {
      _held = null;
      return null;
    }
    return held;
  }

  Future<bool> _ensureFetch() {
    final running = _inFlight;
    if (running != null) return running;
    if (!_active || _unsupported) return Future.value(false);
    _cancelTimer();
    final generation = _generation;
    final fetch = _run(generation);
    _inFlight = fetch;
    return fetch;
  }

  Future<bool> _run(int generation) async {
    LiveSessionOutcome? outcome;
    Object? error;
    try {
      outcome = await _fetch();
    } catch (caught) {
      error = caught;
    }
    if (generation != _generation) return false;
    _inFlight = null;

    if (outcome is LiveSessionReady) {
      final received = _now();
      _held = _Held(outcome, _startBy(outcome, received), received);
      _backoff = null;
      vlog('credentials', 'token held until ${_held!.startBy.toIso8601String()}');
      if (!_paused) _scheduleRefresh(_held!);
      return true;
    }
    if (outcome is LiveSessionRejected &&
        outcome.code == NotebookRuntimeService.routeUnavailableCode) {
      vlog('credentials', 'user-scoped route not deployed; notebook route only');
      _unsupported = true;
      return false;
    }
    vlog('credentials', 'fetch failed: ${error ?? (outcome as LiveSessionRejected).code}');
    _scheduleRetry();
    return false;
  }

  DateTime _startBy(LiveSessionReady ready, DateTime received) {
    final fallback = received.add(fallbackWindow);
    final reported = ready.newSessionExpiresAt ?? fallback;
    return reported.isBefore(ready.expiresAt) ? reported : ready.expiresAt;
  }

  void _scheduleRefresh(_Held held) {
    _cancelTimer();
    final window = held.startBy.difference(held.received);
    final due = held.received.add(window * refreshAt);
    final wait = due.difference(_now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _timer = null;
      if (!_active || _paused || !identical(_held, held)) return;
      if (_now().difference(_lastActivity) >= idleLimit) {
        vlog('credentials', 'idle — refreshes stop until the user returns');
        return;
      }
      vlog('credentials', 'refreshing before the start window lapses');
      _held = null;
      _ensureFetch();
    });
  }

  void _scheduleRetry() {
    if (!_active || _paused) return;
    final previous = _backoff;
    final next = previous == null
        ? minBackoff
        : Duration(
            microseconds: math.min(
              previous.inMicroseconds * 2,
              maxBackoff.inMicroseconds,
            ),
          );
    _backoff = next;
    _cancelTimer();
    _timer = Timer(next, () {
      _timer = null;
      if (!_active || _paused) return;
      if (_now().difference(_lastActivity) >= idleLimit) return;
      _ensureFetch();
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}

class _Held {
  _Held(this.ready, this.startBy, this.received);

  final LiveSessionReady ready;
  final DateTime startBy;
  final DateTime received;
}

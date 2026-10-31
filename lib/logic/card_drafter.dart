import 'dart:async';

import '../models/session_card.dart';
import 'voice_log.dart';

/// Drafts the closing card in the background while a conversation goes on,
/// so leaving can show it at once and only the last few moments are still
/// being written.
///
/// One draft at a time, at most one every [minInterval]: turns saved while
/// a draft runs fold into one follow-up. [stop] (leaving) ends drafting for
/// that notebook, so no draft races the final card; [start] (a new live
/// session in it) resumes. Never throws: a draft is best-effort.
class CardDrafter {
  CardDrafter({
    required Future<SessionCard?> Function(String notebookId) draft,
    this.minInterval = const Duration(seconds: 20),
    DateTime Function() now = DateTime.now,
    Timer Function(Duration, void Function()) startTimer = Timer.new,
  })  : _draft = draft,
        _now = now,
        _startTimer = startTimer;

  final Future<SessionCard?> Function(String notebookId) _draft;
  final Duration minInterval;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _startTimer;

  String? _notebookId;
  String? _stoppedFor;
  bool _inFlight = false;
  bool _dirty = false;
  DateTime? _lastStart;
  Timer? _timer;

  /// Bumped by [stop] and by a switch of notebook: a draft that finishes
  /// after either schedules nothing.
  int _generation = 0;

  /// A turn of [notebookId]'s conversation was saved.
  void turnSaved(String notebookId) {
    if (_stoppedFor == notebookId) return;
    if (_notebookId != notebookId) {
      _reset();
      _notebookId = notebookId;
    }
    if (_inFlight) {
      _dirty = true;
      return;
    }
    _launchOrSchedule();
  }

  /// Leaving [notebookId]: no more drafts for it until [start].
  void stop(String notebookId) {
    _stoppedFor = notebookId;
    if (_notebookId == notebookId) _reset(keepLastStart: true);
  }

  /// A new live session in [notebookId]: drafting resumes.
  void start(String notebookId) {
    if (_stoppedFor == notebookId) _stoppedFor = null;
  }

  void _launchOrSchedule() {
    if (_timer?.isActive ?? false) return;
    final last = _lastStart;
    final since = last == null ? null : _now().difference(last);
    if (since == null || since >= minInterval) {
      _launch();
    } else {
      _timer = _startTimer(minInterval - since, _launch);
    }
  }

  void _launch() {
    final notebookId = _notebookId;
    if (notebookId == null || _stoppedFor == notebookId) return;
    _timer = null;
    _inFlight = true;
    _dirty = false;
    _lastStart = _now();
    final generation = _generation;
    unawaited(Future<SessionCard?>.sync(() => _draft(notebookId))
        .then(
      (card) => vlog('session',
          'card draft ${card == null ? 'skipped' : 'saved'} for $notebookId'),
      onError: (Object error) => vlog(
          'session', 'card draft failed for $notebookId: ${error.runtimeType}'),
    )
        .whenComplete(() {
      if (generation != _generation) return;
      _inFlight = false;
      if (_dirty) {
        _dirty = false;
        _launchOrSchedule();
      }
    }));
  }

  void _reset({bool keepLastStart = false}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _inFlight = false;
    _dirty = false;
    if (!keepLastStart) _lastStart = null;
  }
}

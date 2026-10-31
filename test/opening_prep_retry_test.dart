// A brief request that fails for a reason that can pass (Gemini's rate
// limit, a server error, the network) is kept and retried later, so one
// throttled close doesn't break the chain of openers. Only the latest
// notebook matters: the newest brief wins anyway.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/services/session_brief_service.dart';

class _FakeService implements SessionBriefService {
  final requested = <String>[];

  /// Outcome of each requestBrief, in order; a missing entry succeeds.
  final outcomes = <Object?>[];
  int loads = 0;

  @override
  Future<void> requestBrief(String notebookId) async {
    requested.add(notebookId);
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    if (outcome != null) throw outcome;
  }

  @override
  Future<SessionOpeningState> load() async {
    loads++;
    return const SessionOpeningState(returning: true, brief: null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

const throttled = SessionBriefException('busy', statusCode: 429);

void main() {
  late _FakeService service;
  late List<_FakeTimer> timers;
  late OpeningPrep prep;

  setUp(() {
    service = _FakeService();
    timers = [];
    prep = OpeningPrep(
      service,
      startTimer: (duration, callback) {
        final timer = _FakeTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );
  });

  Future<void> fire(_FakeTimer timer) async {
    timer.callback();
    await pumpEventQueue();
  }

  test('a brief that is written refreshes and leaves nothing pending',
      () async {
    await prep.requestBrief('nb-1');
    expect(service.requested, ['nb-1']);
    expect(service.loads, 1);
    expect(prep.pendingBrief, isNull);
    expect(timers, isEmpty);
  });

  test('a rate-limited brief is retried after 45 s, then cleared on success',
      () async {
    service.outcomes.add(throttled);
    await prep.requestBrief('nb-1');
    expect(prep.pendingBrief, 'nb-1');
    expect(timers.single.duration, const Duration(seconds: 45));

    await fire(timers.single);
    expect(service.requested, ['nb-1', 'nb-1']);
    expect(prep.pendingBrief, isNull);
  });

  test('retries back off 45 s, 2 min, 5 min, then wait for the next resume',
      () async {
    service.outcomes.addAll([throttled, throttled, throttled, throttled]);
    await prep.requestBrief('nb-1');
    await fire(timers[0]);
    await fire(timers[1]);
    await fire(timers[2]);
    expect(timers.map((t) => t.duration), const [
      Duration(seconds: 45),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ]);
    expect(service.requested.length, 4);
    expect(prep.pendingBrief, 'nb-1');

    await prep.retryPendingBrief();
    expect(service.requested.length, 5);
    expect(prep.pendingBrief, isNull);
  });

  test('server errors and network failures are retried too', () async {
    service.outcomes.addAll([
      const SessionBriefException('down', statusCode: 503),
      http.ClientException('offline'),
    ]);
    await prep.requestBrief('nb-1');
    expect(prep.pendingBrief, 'nb-1');
    await fire(timers.single);
    expect(prep.pendingBrief, 'nb-1');
    expect(timers.length, 2);
  });

  test('answers that will not change are not retried', () async {
    for (final status in [400, 401, 404, 422, 501]) {
      service.outcomes.add(SessionBriefException('no', statusCode: status));
      await prep.requestBrief('nb-$status');
    }
    service.outcomes.add(const SessionBriefException('no status'));
    await prep.requestBrief('nb-x');
    expect(prep.pendingBrief, isNull);
    expect(timers, isEmpty);
  });

  test('a newer notebook replaces the pending one and restarts the backoff',
      () async {
    service.outcomes.addAll([throttled, throttled, throttled]);
    await prep.requestBrief('nb-1');
    await fire(timers[0]);
    expect(timers[1].duration, const Duration(minutes: 2));

    await prep.requestBrief('nb-2');
    expect(prep.pendingBrief, 'nb-2');
    expect(timers[1].cancelled, isTrue);
    expect(timers.last.duration, const Duration(seconds: 45));
  });

  test('a newer close whose brief is written supersedes the pending one',
      () async {
    service.outcomes.add(throttled);
    await prep.requestBrief('nb-1');
    await prep.requestBrief('nb-2');
    expect(prep.pendingBrief, isNull);
    expect(timers.single.cancelled, isTrue);
  });

  test('a newer close that fails for a final reason keeps the pending one',
      () async {
    service.outcomes
      ..add(throttled)
      ..add(const SessionBriefException('silent', statusCode: 422));
    await prep.requestBrief('nb-1');
    await prep.requestBrief('nb-2');
    expect(prep.pendingBrief, 'nb-1');
    expect(timers.single.cancelled, isFalse);
  });

  test('retryPendingBrief with nothing pending does nothing', () async {
    await prep.retryPendingBrief();
    expect(service.requested, isEmpty);
  });

  test('sign-out drops the pending brief and its timer', () async {
    service.outcomes.add(throttled);
    await prep.requestBrief('nb-1');
    prep.clear();
    expect(prep.pendingBrief, isNull);
    expect(timers.single.cancelled, isTrue);
    await prep.retryPendingBrief();
    expect(service.requested, ['nb-1']);
  });

  test('a request that fails after sign-out does not become pending', () async {
    final gate = Completer<void>();
    final slow = _SlowService(gate.future);
    final p = OpeningPrep(slow, startTimer: (d, c) => _FakeTimer(d, c));
    final pending = p.requestBrief('nb-1');
    p.clear();
    gate.completeError(throttled);
    await pending;
    expect(p.pendingBrief, isNull);
  });

  test('requestBrief never throws', () async {
    service.outcomes.add(StateError('not configured'));
    await expectLater(prep.requestBrief('nb-1'), completes);
  });
}

class _SlowService implements SessionBriefService {
  _SlowService(this._result);
  final Future<void> _result;

  @override
  Future<void> requestBrief(String notebookId) => _result;

  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: true, brief: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

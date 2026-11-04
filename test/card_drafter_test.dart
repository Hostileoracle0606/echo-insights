// While a conversation goes on, the closing card is drafted in the
// background so leaving can show it at once. One draft at a time, at most
// one every 20 s; turns saved meanwhile fold into one follow-up draft.
// Leaving stops it, so no draft races the final card.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/card_drafter.dart';
import 'package:lumen/models/session_card.dart';

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

void main() {
  late List<String> drafted;
  late List<Completer<SessionCard?>> pending;
  late List<_FakeTimer> timers;
  late DateTime clock;
  late CardDrafter drafter;

  setUp(() {
    drafted = [];
    pending = [];
    timers = [];
    clock = DateTime(2026, 10, 31, 12);
    drafter = CardDrafter(
      draft: (notebookId) {
        drafted.add(notebookId);
        final c = Completer<SessionCard?>();
        pending.add(c);
        return c.future;
      },
      now: () => clock,
      startTimer: (duration, callback) {
        final t = _FakeTimer(duration, callback);
        timers.add(t);
        return t;
      },
    );
  });

  Future<void> finish(int i, {Object? error}) async {
    if (error != null) {
      pending[i].completeError(error);
    } else {
      pending[i].complete(null);
    }
    await pumpEventQueue();
  }

  test('the first saved turn drafts at once', () {
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1']);
  });

  test('turns saved while a draft runs fold into one follow-up', () async {
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1']);

    clock = clock.add(const Duration(seconds: 25));
    await finish(0);
    expect(drafted, ['nb-1', 'nb-1']);
  });

  test('a follow-up waits out the rest of the 20 s since the last draft',
      () async {
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    clock = clock.add(const Duration(seconds: 4));
    await finish(0);
    expect(drafted, ['nb-1']);
    expect(timers.single.duration, const Duration(seconds: 16));

    timers.single.callback();
    expect(drafted, ['nb-1', 'nb-1']);
  });

  test('a turn saved within 20 s of a finished draft is scheduled, not sent',
      () async {
    drafter.turnSaved('nb-1');
    clock = clock.add(const Duration(seconds: 3));
    await finish(0);
    clock = clock.add(const Duration(seconds: 2));
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1']);
    expect(timers.single.duration, const Duration(seconds: 15));
  });

  test('a failed draft is fine: the next saved turn drafts again', () async {
    drafter.turnSaved('nb-1');
    clock = clock.add(const Duration(seconds: 21));
    await finish(0, error: StateError('throttled'));
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1', 'nb-1']);
  });

  test('leaving stops drafting, including a scheduled or folded one', () async {
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    drafter.stop('nb-1');
    clock = clock.add(const Duration(seconds: 30));
    await finish(0);
    expect(drafted, ['nb-1']);

    // The drain's last commit lands after leaving began: still no draft.
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1']);
  });

  test('stop cancels a waiting follow-up', () async {
    drafter.turnSaved('nb-1');
    drafter.turnSaved('nb-1');
    await finish(0);
    drafter.stop('nb-1');
    expect(timers.single.cancelled, isTrue);
  });

  test('a new session in the notebook drafts again', () async {
    drafter.turnSaved('nb-1');
    drafter.stop('nb-1');
    await finish(0);
    drafter.start('nb-1');
    clock = clock.add(const Duration(seconds: 30));
    drafter.turnSaved('nb-1');
    expect(drafted, ['nb-1', 'nb-1']);
  });

  test('another notebook starts fresh', () async {
    drafter.turnSaved('nb-1');
    drafter.stop('nb-1');
    drafter.turnSaved('nb-2');
    expect(drafted, ['nb-1', 'nb-2']);
  });
}

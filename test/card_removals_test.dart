// CardRemovals: "Lumen will remember" removals on the closing card (LM-16).
// A removal hides the row at once and reaches memory only when its undo
// window ends, or at once when the app leaves the foreground.
import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/card_removals.dart';

/// Timers that fire only when the test moves time forward.
class _FakeClock {
  Duration _now = Duration.zero;
  final _timers = <_FakeTimer>[];

  Timer start(Duration after, void Function() callback) {
    final timer = _FakeTimer(_now + after, callback);
    _timers.add(timer);
    return timer;
  }

  void elapse(Duration by) {
    _now += by;
    for (final timer in _timers.toList()) {
      if (timer.isActive && timer.due <= _now) timer.fire();
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this._callback);

  final Duration due;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

void main() {
  late _FakeClock clock;
  late List<String> sent;
  late List<String> failed;
  late CardRemovals removals;
  Object? failWith;

  setUp(() {
    clock = _FakeClock();
    sent = [];
    failed = [];
    failWith = null;
    removals = CardRemovals(
      remove: (id) async {
        sent.add(id);
        if (failWith != null) throw failWith!;
      },
      startTimer: clock.start,
      onFailed: failed.add,
    );
  });

  test('a removal hides the item at once and sends it once after 5 s',
      () async {
    removals.remove('priya');
    expect(removals.isHidden('priya'), isTrue);

    clock.elapse(const Duration(milliseconds: 4999));
    await pumpEventQueue();
    expect(sent, isEmpty);

    clock.elapse(const Duration(milliseconds: 1));
    await pumpEventQueue();
    expect(sent, ['priya']);
    expect(removals.isHidden('priya'), isTrue);

    clock.elapse(const Duration(seconds: 30));
    await pumpEventQueue();
    expect(sent, ['priya'], reason: 'exactly once');
  });

  test('undo inside the window brings it back and sends nothing', () async {
    removals.remove('priya');
    clock.elapse(const Duration(seconds: 2));
    expect(removals.undo('priya'), isTrue);
    expect(removals.isHidden('priya'), isFalse);

    clock.elapse(const Duration(seconds: 10));
    await pumpEventQueue();
    expect(sent, isEmpty);
  });

  test('undo after the window has passed does nothing', () async {
    removals.remove('priya');
    clock.elapse(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(removals.undo('priya'), isFalse);
    expect(removals.isHidden('priya'), isTrue);
  });

  test('removing the same item twice is one removal', () async {
    removals
      ..remove('priya')
      ..remove('priya');
    clock.elapse(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(sent, ['priya']);
  });

  test('going to the background sends pending removals at once', () async {
    removals
      ..remove('priya')
      ..remove('staging_db');
    removals.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(sent, unorderedEquals(['priya', 'staging_db']));

    clock.elapse(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(sent, hasLength(2), reason: 'the timers were cancelled');
  });

  test('returning to the foreground sends nothing', () async {
    removals.remove('priya');
    removals
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(sent, isEmpty);
  });

  test('dispose sends what is still pending', () async {
    removals.remove('priya');
    removals.dispose();
    await pumpEventQueue();
    expect(sent, ['priya']);
  });

  test('a failed removal shows the item again and reports it', () async {
    failWith = Exception('offline');
    var changes = 0;
    removals.addListener(() => changes++);

    removals.remove('priya');
    clock.elapse(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(removals.isHidden('priya'), isFalse);
    expect(failed, ['priya']);
    expect(changes, 2, reason: 'hidden, then shown again');
  });
}

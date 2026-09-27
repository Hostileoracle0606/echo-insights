import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_runtime_service.dart';

final _t0 = DateTime.utc(2026, 9, 27, 12);

/// A runtime that answers each fetch with the next scripted outcome and
/// issues tokens with a 10-minute start window from the fake clock.
class _FakeRuntime {
  _FakeRuntime(this.now);

  final DateTime Function() now;
  int calls = 0;
  final outcomes = <Object Function()>[];
  Completer<LiveSessionOutcome>? gate;

  static LiveSessionOutcome Function() readyAt(DateTime issued, int n) {
    return () => LiveSessionReady(
          sessionToken: 'auth_tokens/t$n',
          expiresAt: issued.add(const Duration(minutes: 30)),
          newSessionExpiresAt: issued.add(const Duration(minutes: 10)),
          model: 'gemini-3.1-flash-live-preview',
        );
  }

  Future<LiveSessionOutcome> fetch() async {
    calls += 1;
    final pending = gate;
    if (pending != null) return pending.future;
    if (outcomes.isNotEmpty) {
      final next = outcomes.removeAt(0)();
      if (next is LiveSessionOutcome) return next;
      throw next;
    }
    return readyAt(now(), calls)();
  }
}

void main() {
  late DateTime Function() now;
  late _FakeRuntime runtime;
  late LiveCredentials credentials;

  void setUpWith(FakeAsync async) {
    now = () => async.getClock(_t0).now().toUtc();
    runtime = _FakeRuntime(now);
    credentials = LiveCredentials(fetch: runtime.fetch, now: now);
  }

  test('fetches a token at sign-in and holds it', () {
    fakeAsync((async) {
      setUpWith(async);
      expect(credentials.phase, LiveCredentialsPhase.none);
      credentials.start();
      expect(credentials.phase, LiveCredentialsPhase.fetching);
      async.flushMicrotasks();
      expect(runtime.calls, 1);
      expect(credentials.phase, LiveCredentialsPhase.held);
    });
  });

  test('take hands out the held token at once, then fetches the next', () {
    fakeAsync((async) {
      setUpWith(async);
      credentials.start();
      async.flushMicrotasks();

      LiveSessionReady? taken;
      credentials.take().then((value) => taken = value);
      async.flushMicrotasks();

      expect(taken?.sessionToken, 'auth_tokens/t1');
      expect(runtime.calls, 2);
      expect(credentials.phase, LiveCredentialsPhase.held);

      LiveSessionReady? second;
      credentials.take().then((value) => second = value);
      async.flushMicrotasks();
      expect(second?.sessionToken, 'auth_tokens/t2');
    });
  });

  test('refreshes before the start window lapses (at 8 of 10 minutes)', () {
    fakeAsync((async) {
      setUpWith(async);
      credentials.start();
      async.flushMicrotasks();
      expect(runtime.calls, 1);

      async.elapse(const Duration(minutes: 7, seconds: 59));
      expect(runtime.calls, 1);
      credentials.noteActivity();
      async.elapse(const Duration(seconds: 2));
      expect(runtime.calls, 2);
      expect(credentials.phase, LiveCredentialsPhase.held);
    });
  });

  test('a take waits for a fetch in flight and never shares a token', () {
    fakeAsync((async) {
      setUpWith(async);
      runtime.gate = Completer();
      credentials.start();
      async.flushMicrotasks();

      final taken = <String?>[];
      credentials.take().then((value) => taken.add(value?.sessionToken));
      credentials.take().then((value) => taken.add(value?.sessionToken));
      async.flushMicrotasks();
      expect(taken, isEmpty);

      final gate = runtime.gate!;
      runtime.gate = null;
      gate.complete(_FakeRuntime.readyAt(now(), 1)());
      async.flushMicrotasks();

      expect(taken, hasLength(2));
      expect(taken.toSet(), hasLength(2), reason: 'each caller gets its own');
      expect(taken.whereType<String>(), hasLength(2));
    });
  });

  test('stops refreshing when idle and fetches again on the next activity', () {
    fakeAsync((async) {
      setUpWith(async);
      credentials.start();
      async.flushMicrotasks();

      // Refreshes at 8, 16, 24 min keep going while the user was active
      // within the idle limit (30 min); the one at 32 min is skipped.
      async.elapse(const Duration(minutes: 40));
      final callsWhenIdle = runtime.calls;
      async.elapse(const Duration(hours: 1));
      expect(runtime.calls, callsWhenIdle, reason: 'no refresh while idle');
      expect(credentials.phase, LiveCredentialsPhase.none);

      credentials.noteActivity();
      async.flushMicrotasks();
      expect(runtime.calls, callsWhenIdle + 1);
      expect(credentials.phase, LiveCredentialsPhase.held);
    });
  });

  test('does not hand out a token whose start window has lapsed', () {
    fakeAsync((async) {
      setUpWith(async);
      credentials.start();
      async.flushMicrotasks();
      credentials.pause(); // no refreshes
      async.elapse(const Duration(minutes: 11));

      LiveSessionReady? taken;
      credentials.take().then((value) => taken = value);
      async.flushMicrotasks();

      expect(runtime.calls, 2, reason: 'the lapsed token was replaced');
      expect(taken?.sessionToken, 'auth_tokens/t2');
    });
  });

  test('backs off quietly after failures and recovers', () {
    fakeAsync((async) {
      setUpWith(async);
      runtime.outcomes.addAll([
        () => StateError('offline'),
        () => const LiveSessionRejected('providerUnavailable'),
        () => StateError('offline'),
      ]);
      credentials.start();
      async.flushMicrotasks();
      expect(runtime.calls, 1);

      async.elapse(const Duration(seconds: 2));
      expect(runtime.calls, 2);
      async.elapse(const Duration(seconds: 3));
      expect(runtime.calls, 2, reason: 'second back-off is 4 s');
      async.elapse(const Duration(seconds: 1));
      expect(runtime.calls, 3);
      async.elapse(const Duration(seconds: 8));
      expect(runtime.calls, 4);
      expect(credentials.phase, LiveCredentialsPhase.held);
    });
  });

  test('a take after a failed fetch returns null instead of throwing', () {
    fakeAsync((async) {
      setUpWith(async);
      runtime.outcomes.addAll([
        () => StateError('offline'),
        () => StateError('offline'),
      ]);
      credentials.start();
      async.flushMicrotasks();

      Object? taken = 'pending';
      credentials.take().then((value) => taken = value);
      async.flushMicrotasks();
      expect(taken, isNull);
    });
  });

  test('an undeployed user route disables fetching until the next sign-in', () {
    fakeAsync((async) {
      setUpWith(async);
      runtime.outcomes.add(
        () => const LiveSessionRejected(
          NotebookRuntimeService.routeUnavailableCode,
        ),
      );
      credentials.start();
      async.flushMicrotasks();
      expect(credentials.unsupported, isTrue);

      Object? taken = 'pending';
      credentials.take().then((value) => taken = value);
      async.elapse(const Duration(minutes: 5));
      expect(taken, isNull);
      expect(runtime.calls, 1);

      credentials.stop();
      credentials.start();
      async.flushMicrotasks();
      expect(credentials.unsupported, isFalse);
      expect(credentials.phase, LiveCredentialsPhase.held);
    });
  });

  test('sign-out clears the token and ignores a fetch in flight', () {
    fakeAsync((async) {
      setUpWith(async);
      credentials.start();
      async.flushMicrotasks();
      runtime.gate = Completer();
      credentials.take();
      async.flushMicrotasks();
      expect(credentials.phase, LiveCredentialsPhase.fetching);

      credentials.stop();
      runtime.gate!.complete(_FakeRuntime.readyAt(now(), 9)());
      async.flushMicrotasks();

      expect(credentials.phase, LiveCredentialsPhase.none);
      Object? taken = 'pending';
      credentials.take().then((value) => taken = value);
      async.flushMicrotasks();
      expect(taken, isNull);
      async.elapse(const Duration(hours: 1));
      expect(runtime.calls, 2, reason: 'nothing runs after sign-out');
    });
  });

  test('a runtime without newSessionExpiresAt is treated as a 60 s window', () {
    fakeAsync((async) {
      setUpWith(async);
      runtime.outcomes.add(
        () => LiveSessionReady(
          sessionToken: 'auth_tokens/legacy',
          expiresAt: now().add(const Duration(minutes: 30)),
          model: 'gemini-3.1-flash-live-preview',
        ),
      );
      credentials.start();
      async.flushMicrotasks();
      credentials.pause();
      async.elapse(const Duration(seconds: 56));

      LiveSessionReady? taken;
      credentials.take().then((value) => taken = value);
      async.flushMicrotasks();
      expect(taken?.sessionToken, isNot('auth_tokens/legacy'));
    });
  });
}

// LM-103: the catch-up runner (one step at a time, bounded, cancellable,
// never throws) and the scheduler (single flight, waits for the app lock).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/catch_up_service.dart';
import 'package:lumen/services/headless_turn_finisher.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/unfinished_work_service.dart';

/// Every dependency of a runner, as fakes the test can steer and inspect.
class Rig {
  Rig({this.work = const [UnfinishedWork.empty]});

  /// What each successive `get_unfinished_work` call returns (the last one
  /// repeats).
  List<UnfinishedWork> work;
  int loads = 0;
  Object? loadError;

  List<String> journalIds = [];
  String? open;
  final live = <String>{};

  /// Per notebook: the turn finisher's answer (default: all committed).
  final finishResults = <String, NotebookFinishResult>{};
  int finishers = 0;

  /// Per notebook: the source revision the card ended at (default: the
  /// requested one), or an error to throw.
  final cardRevisions = <String, int?>{};
  final cardErrors = <String, Object>{};
  final briefErrors = <String, Object>{};

  /// A step that never finishes until released (keyed by call name).
  final hold = <String, Completer<void>>{};

  final calls = <String>[];
  int running = 0;
  int maxRunning = 0;

  final skips = MemoryCatchUpSkipStore();
  final pendingSeen = <Set<String>>[];

  DateTime clock = DateTime.utc(2026, 11, 16, 9);

  /// Timers the runner asked for, released by [fireDelays].
  final delays = <({Duration duration, Completer<void> done})>[];

  void fireDelays() {
    for (final d in List.of(delays)) {
      if (!d.done.isCompleted) d.done.complete();
    }
  }

  Future<T> _step<T>(String name, Future<T> Function() body) async {
    calls.add(name);
    running++;
    if (running > maxRunning) maxRunning = running;
    try {
      final h = hold[name];
      if (h != null) await h.future;
      return await body();
    } finally {
      running--;
    }
  }

  CatchUpRunner runner({
    Duration budget = CatchUpRunner.defaultBudget,
    Duration stepTimeout = CatchUpRunner.defaultStepTimeout,
    bool vectors = false,
    Set<String>? turnsStillRunning,
  }) {
    return CatchUpRunner(
      loadWork: () async {
        loads++;
        if (loadError != null) throw loadError!;
        return work[(loads - 1).clamp(0, work.length - 1)];
      },
      journalNotebookIds: () async => List.of(journalIds),
      newTurnFinisher: () {
        finishers++;
        return (notebookId) => _step('turns:$notebookId', () async {
              final result = finishResults[notebookId] ??
                  NotebookFinishResult(
                    notebookId: notebookId,
                    committedTurnIds: const ['t1'],
                  );
              if (result.done) journalIds.remove(notebookId);
              return result;
            });
      },
      closeCard: (notebookId) => _step('card:$notebookId', () async {
        final error = cardErrors[notebookId];
        if (error != null) throw error;
        return cardRevisions.containsKey(notebookId)
            ? cardRevisions[notebookId]
            : 999;
      }),
      requestBrief: (notebookId) => _step('brief:$notebookId', () async {
        final error = briefErrors[notebookId];
        if (error != null) throw error;
      }),
      runErase: (jobId) => _step('erase:$jobId', () async => true),
      buildVectors: vectors
          ? (step) => _step('vectors:${step.notebookId}', () async {})
          : null,
      skips: skips,
      openNotebookId: () => open,
      isNotebookLive: live.contains,
      turnsStillRunning: turnsStillRunning,
      budget: budget,
      stepTimeout: stepTimeout,
      now: () => clock,
      delay: (duration) {
        final done = Completer<void>();
        delays.add((duration: duration, done: done));
        return done.future;
      },
      onPendingCards: (ids) => pendingSeen.add(Set.of(ids)),
    );
  }
}

UnfinishedWork work({
  List<UnfinishedCard> cards = const [],
  List<UnfinishedBrief> briefs = const [],
  List<UnfinishedVectors> vectors = const [],
  List<UnfinishedErase> erase = const [],
}) =>
    UnfinishedWork(
      cards: cards,
      briefs: briefs,
      vectors: vectors,
      erase: erase,
      truncated: false,
    );

UnfinishedCard card(String id, int revision) =>
    UnfinishedCard(notebookId: id, revision: revision);

List<String> outcomes(CatchUpReport report) => [
      for (final r in report.records) '${r.step} ${r.outcome.name}',
    ];

void main() {
  group('CatchUpRunner', () {
    test('runs every step one at a time, in plan order', () async {
      final rig = Rig(work: [
        work(
          cards: [card('a', 3)],
          briefs: [const UnfinishedBrief(notebookId: 'a', revision: 3)],
          erase: [
            const UnfinishedErase(jobId: 'job1', nextBatch: 2, rewritten: 4),
          ],
        ),
      ]);
      final report = await rig.runner().run();

      expect(rig.calls, ['card:a', 'brief:a', 'erase:job1']);
      expect(rig.maxRunning, 1);
      expect(report.cancelled, isFalse);
      expect(report.budgetExhausted, isFalse);
      expect(report.cardsWritten, 1);
      expect(report.briefsWritten, 1);
      expect(rig.loads, 1, reason: 'no turns: one plan is enough');
    });

    test(
        'after journalled turns commit it reads the work again, and the card '
        'that follows is made', () async {
      final rig = Rig(work: [
        UnfinishedWork.empty,
        // The commit moved the notebook to r5: now it lacks a card.
        work(cards: [card('a', 5)]),
      ])
        ..journalIds = ['a'];
      final report = await rig.runner().run();

      expect(rig.calls, ['turns:a', 'card:a']);
      expect(rig.loads, 2);
      expect(report.plans, 2);
      expect(outcomes(report), [
        'FinishTurnsStep(a) done',
        'CardStep(a, r5) done',
      ]);
    });

    test('a new turn finisher for every run', () async {
      final rig = Rig()..journalIds = ['a'];
      await rig.runner().run();
      rig.journalIds = ['a'];
      await rig.runner().run();
      expect(rig.finishers, 2);
    });

    test('a deferred notebook keeps its turns and gets no card this run',
        () async {
      final rig = Rig(work: [
        work(cards: [card('a', 2)]),
        work(cards: [card('a', 2)]),
      ])
        ..journalIds = ['a'];
      rig.finishResults['a'] = const NotebookFinishResult(
        notebookId: 'a',
        deferredTurnId: 't1',
      );
      final report = await rig.runner().run();

      expect(rig.calls, ['turns:a']);
      expect(outcomes(report), [
        'FinishTurnsStep(a) deferred',
        'CardStep(a, r2) deferred',
      ]);
    });

    test(
        'never finishes the turns of the notebook a session has open; its '
        'other steps wait while it is live', () async {
      final rig = Rig(work: [
        work(cards: [card('open', 1), card('live', 1), card('b', 1)]),
      ])
        ..journalIds = ['open', 'live']
        ..open = 'open'
        ..live.add('live');
      final report = await rig.runner().run();

      // Turns first (all of them), then the rest. A notebook whose words
      // are still journalled gets no card yet: it would miss them.
      expect(rig.calls, ['card:b']);
      expect(outcomes(report), [
        'FinishTurnsStep(open) skippedLive',
        'FinishTurnsStep(live) skippedLive',
        'CardStep(open, r1) deferred',
        'CardStep(live, r1) skippedLive',
        'CardStep(b, r1) done',
      ]);
    });

    test('the open notebook goes first, and its card runs when not live',
        () async {
      final rig = Rig(work: [
        work(cards: [card('b', 1), card('open', 1)]),
      ])
        ..open = 'open';
      await rig.runner().run();
      expect(rig.calls, ['card:open', 'card:b']);
    });

    test(
        'a card the runtime will not write at this revision is remembered '
        'and skipped until the revision moves', () async {
      final rig = Rig(work: [
        work(cards: [card('a', 4)]),
      ]);
      rig.cardRevisions['a'] = null; // 422: nothing to summarize
      var report = await rig.runner().run();
      expect(outcomes(report), ['CardStep(a, r4) terminal']);
      expect(await rig.skips.read(), {'card:a': 4});

      rig.calls.clear();
      report = await rig.runner().run();
      expect(rig.calls, isEmpty);
      expect(outcomes(report), ['CardStep(a, r4) alreadyTerminal']);

      rig.work = [
        work(cards: [card('a', 6)]),
      ];
      rig.cardRevisions['a'] = 6;
      report = await rig.runner().run();
      expect(rig.calls, ['card:a']);
      expect(outcomes(report), ['CardStep(a, r6) done']);
      expect(await rig.skips.read(), isEmpty);
    });

    test('a card that comes back for an older revision is terminal too',
        () async {
      final rig = Rig(work: [
        work(cards: [card('a', 4)]),
      ]);
      rig.cardRevisions['a'] = 2;
      final report = await rig.runner().run();
      expect(outcomes(report), ['CardStep(a, r4) terminal']);
    });

    test('a brief with nothing to write from (422) is terminal', () async {
      final rig = Rig(work: [
        work(briefs: [const UnfinishedBrief(notebookId: 'a', revision: 2)]),
      ]);
      rig.briefErrors['a'] =
          const SessionBriefException('nothing', statusCode: 422);
      var report = await rig.runner().run();
      expect(outcomes(report), ['BriefStep(a, r2) terminal']);
      report = await rig.runner().run();
      expect(outcomes(report), ['BriefStep(a, r2) alreadyTerminal']);
    });

    test('a failing step is left for next time and the rest still run',
        () async {
      final rig = Rig(work: [
        work(cards: [card('a', 1), card('b', 1)]),
      ]);
      rig.cardErrors['a'] = const SocketException('offline');
      final report = await rig.runner().run();
      expect(rig.calls, ['card:a', 'card:b']);
      expect(outcomes(report), [
        'CardStep(a, r1) failed',
        'CardStep(b, r1) done',
      ]);
      expect(await rig.skips.read(), isEmpty);
    });

    test('never throws: an unreadable work list ends the run quietly',
        () async {
      final rig = Rig()..loadError = StateError('offline');
      final report = await rig.runner().run();
      expect(report.loadFailed, isTrue);
      expect(report.records, isEmpty);
    });

    test('journalled turns still finish when the work list cannot be read',
        () async {
      final rig = Rig()
        ..journalIds = ['a']
        ..loadError = const SocketException('offline');
      final report = await rig.runner().run();
      expect(rig.calls, ['turns:a']);
      expect(report.loadFailed, isTrue);
    });

    test('a step that hangs is timed out and the next one runs', () async {
      final rig = Rig(work: [
        work(cards: [card('a', 1), card('b', 1)]),
      ]);
      rig.hold['card:a'] = Completer<void>();
      final running = rig.runner(stepTimeout: const Duration(seconds: 5)).run();
      await pumpEventQueue();
      expect(rig.calls, ['card:a']);
      expect(rig.delays.single.duration, const Duration(seconds: 5));
      rig.fireDelays();
      final report = await running;
      expect(outcomes(report), [
        'CardStep(a, r1) timedOut',
        'CardStep(b, r1) done',
      ]);
    });

    test('the per-step timeout never runs past what is left of the budget',
        () async {
      final rig = Rig(work: [
        work(cards: [card('a', 1)]),
      ]);
      rig.hold['card:a'] = Completer<void>();
      final running = rig
          .runner(
            budget: const Duration(seconds: 60),
            stepTimeout: const Duration(seconds: 30),
          )
          .run();
      rig.clock = rig.clock.add(const Duration(seconds: 50));
      await pumpEventQueue();
      expect(rig.delays.single.duration, const Duration(seconds: 10));
      rig.fireDelays();
      await running;
    });

    test('the time budget stops the run; what is left waits for next time',
        () async {
      final rig = Rig(work: [
        work(cards: [card('a', 1), card('b', 1)]),
      ]);
      final runner = rig.runner(budget: const Duration(seconds: 60));
      rig.hold['card:a'] = Completer<void>();
      final running = runner.run();
      await pumpEventQueue();
      rig.clock = rig.clock.add(const Duration(seconds: 61));
      rig.hold['card:a']!.complete();
      final report = await running;
      expect(rig.calls, ['card:a']);
      expect(report.budgetExhausted, isTrue);
      expect(outcomes(report), ['CardStep(a, r1) done']);
    });

    test('cancel stops the run between steps and mid-step', () async {
      final rig = Rig(work: [
        work(cards: [card('a', 1), card('b', 1)]),
      ]);
      rig.hold['card:a'] = Completer<void>();
      final token = CatchUpCancelToken();
      final running = rig.runner().run(token);
      await pumpEventQueue();
      token.cancel();
      final report = await running;
      expect(report.cancelled, isTrue);
      expect(rig.calls, ['card:a']);
      expect(outcomes(report), ['CardStep(a, r1) cancelled']);
    });

    test('a turn step still running from an earlier run is not started again',
        () async {
      final still = <String>{};
      final rig = Rig()..journalIds = ['a'];
      rig.hold['turns:a'] = Completer<void>();
      final first =
          rig
          .runner(
            turnsStillRunning: still,
            stepTimeout: const Duration(seconds: 1),
          )
          .run();
      await pumpEventQueue();
      rig.fireDelays(); // the first run times out; the finish carries on
      await first;
      expect(still, {'a'});

      final second = await rig.runner(turnsStillRunning: still).run();
      expect(outcomes(second), ['FinishTurnsStep(a) stillRunning']);
      expect(rig.calls, ['turns:a']);

      rig.hold['turns:a']!.complete();
      await pumpEventQueue();
      expect(still, isEmpty);
    });

    test('without an on-device vector build the server catches up', () async {
      final rig = Rig(work: [
        work(vectors: [
          const UnfinishedVectors(notebookId: 'a', entityCount: 3, missing: 2),
        ]),
      ]);
      var report = await rig.runner().run();
      expect(rig.calls, isEmpty);
      expect(outcomes(report), ['VectorsStep(a, 2 missing) serverCatchesUp']);

      report = await rig.runner(vectors: true).run();
      expect(rig.calls, ['vectors:a']);
      expect(outcomes(report), ['VectorsStep(a, 2 missing) done']);
    });

    test('reports which notebooks still wait for a card, then none', () async {
      final rig = Rig(work: [
        work(cards: [card('b', 1)]),
        work(cards: [card('a', 2), card('b', 1)]),
      ])
        ..journalIds = ['a'];
      await rig.runner().run();
      expect(rig.pendingSeen.first, {'a', 'b'});
      expect(rig.pendingSeen, contains(equals({'b'})));
      expect(rig.pendingSeen.last, isEmpty);
    });
  });

  group('CatchUpScheduler', () {
    late List<Completer<CatchUpReport>> runs;
    late List<CatchUpCancelToken> tokens;
    late List<bool> runningSeen;
    late CatchUpScheduler scheduler;

    setUp(() {
      runs = [];
      tokens = [];
      runningSeen = [];
      scheduler = CatchUpScheduler(
        run: (token) {
          tokens.add(token);
          final c = Completer<CatchUpReport>();
          runs.add(c);
          return c.future;
        },
        onRunning: runningSeen.add,
      );
    });

    void finish(int i) => runs[i].complete(CatchUpReport.empty);

    test('waits for the app lock to open', () async {
      scheduler.request();
      expect(runs, isEmpty);
      scheduler.setUnlocked(true);
      expect(runs, hasLength(1));
      expect(runningSeen, [true]);
      finish(0);
      await pumpEventQueue();
      expect(runningSeen, [true, false]);
      expect(scheduler.isRunning, isFalse);
    });

    test('unlocking with nothing asked for runs nothing', () {
      scheduler.setUnlocked(true);
      expect(runs, isEmpty);
    });

    test(
        'a trigger while a run is going is folded into one follow-up run '
        '(launch and resume never overlap)', () async {
      scheduler.setUnlocked(true);
      scheduler.request();
      scheduler.request();
      scheduler.request();
      expect(runs, hasLength(1));
      finish(0);
      await pumpEventQueue();
      expect(runs, hasLength(2));
      finish(1);
      await pumpEventQueue();
      expect(runs, hasLength(2));
    });

    test('locking cancels the run and runs again after unlock', () async {
      scheduler.setUnlocked(true);
      scheduler.request();
      scheduler.setUnlocked(false);
      expect(tokens.single.isCancelled, isTrue);
      finish(0);
      await pumpEventQueue();
      expect(runs, hasLength(1));
      scheduler.setUnlocked(true);
      expect(runs, hasLength(2));
    });

    test('sign-out cancels and forgets what was asked', () async {
      scheduler.request();
      scheduler.signedOut();
      scheduler.setUnlocked(true);
      expect(runs, isEmpty);

      scheduler.request();
      scheduler.request();
      scheduler.signedOut();
      expect(tokens.single.isCancelled, isTrue);
      finish(0);
      await pumpEventQueue();
      expect(runs, hasLength(1), reason: 'no follow-up for the old account');
    });

    test('a run that throws does not wedge the scheduler', () async {
      scheduler.setUnlocked(true);
      scheduler.request();
      runs[0].completeError(StateError('boom'));
      await pumpEventQueue();
      expect(scheduler.isRunning, isFalse);
      scheduler.request();
      expect(runs, hasLength(2));
    });
  });

  group('FileCatchUpSkipStore', () {
    test('keeps ids and revisions across instances; unreadable is empty',
        () async {
      final dir = await Directory.systemTemp.createTemp('catch_up_skips');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileCatchUpSkipStore(directoryProvider: () async => dir);
      expect(await store.read(), isEmpty);
      await store.write({'card:a': 3});
      expect(
        await FileCatchUpSkipStore(directoryProvider: () async => dir).read(),
        {'card:a': 3},
      );
      final file = File('${dir.path}/catch_up/skips.json');
      await file.writeAsString('not json');
      expect(await store.read(), isEmpty);
    });
  });
}

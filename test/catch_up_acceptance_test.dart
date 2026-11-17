// LM-103 acceptance: the five failure cases of launch-time catch-up.
//
// Each case drives the real catch-up stack (CatchUpRunner, CatchUpScheduler,
// HeadlessTurnFinisher, SessionCardService, SessionBriefService,
// UnfinishedWorkService, a real TurnJournalService and FileCatchUpSkipStore
// on a temp directory) against one in-memory FakeLumenServer that applies
// the server's own rules (commit ledger, keyed card and brief saves,
// get_unfinished_work computed from its tables). "Exactly once" is asserted
// on what the server holds (rows written) and on the model calls it counted.
//
// A relaunch is a new runner, new finisher and new services over the same
// journal directory and skip store. No real timers or sleeps: the runner's
// clock and delay are injected (the delay never fires).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_commit.dart';
import 'package:lumen/logic/turn_state.dart'
    show DurableStage, FinalizedTurn, Speaker;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/providers/journal_provider.dart'
    show SessionStatus, catchUpOwnsNotebook, sessionIsLive;
import 'package:lumen/services/catch_up_service.dart';
import 'package:lumen/services/retrieve_memory_service.dart';
import 'package:lumen/services/unfinished_work_service.dart';

import 'support/fake_lumen_server.dart';
import 'support/pseudonyms.dart' show entity;

const _nb = 'notebook-1';

FinalizedTurn _turn(
  String turnId,
  String text, {
  String notebookId = _nb,
  DurableStage stage = DurableStage.finalRecorded,
}) =>
    FinalizedTurn(
      turnId: turnId,
      sessionId: 'session-1',
      notebookId: notebookId,
      speaker: Speaker.user,
      transcript: text,
      transcriptVersion: 1,
      transcriptHash: 'hash-$turnId',
      extractorVersion: 'gemini/extract_graph/v2',
      generation: 1,
      commitRequestId: 'request-$turnId',
      stage: stage,
      finalizedAt: '2026-11-16T08:30:00.000Z',
    );

const _priya = GraphPatch(
  entities: [EntityPatch(name: 'Priya', type: EntityType.person)],
  relations: [],
  supersedes: [],
);

List<String> _outcomes(CatchUpReport report) => [
      for (final r in report.records) '${r.step} ${r.outcome.name}',
    ];

/// What the server holds and has paid for, to compare before and after.
({int rows, int models, int requests}) _tally(FakeLumenServer server) => (
      rows: server.rowsWritten,
      models: server.modelCalls,
      requests: server.commitRequestIds.length,
    );

/// The phone was killed after it prepared (and persisted) the commit for
/// [turn], before the commit was sent: what `JournalNotifier._runCommit`
/// leaves in the journal. Built with the shared merge (`prepareTurnCommit`).
Future<FinalizedTurn> _journalPreparedCommit(
  Phone phone,
  FakeLumenServer server,
  FinalizedTurn turn,
  GraphPatch patch,
) async {
  final snapshot = server.snapshotOf(turn.notebookId)!;
  final made = prepareTurnCommit(
    state: snapshot.state,
    turn: turn,
    patch: patch,
    expectedRevision: snapshot.revision,
  );
  final pending = turn.copyWith(
    stage: DurableStage.commitPending,
    extraction: patch.toJson(),
    baseRevision: snapshot.revision,
  );
  await phone.journal().persistPreparedCommit(
        turn: pending,
        preparedCommit: made.prepared,
      );
  return pending;
}

void main() {
  late FakeLumenServer server;

  setUp(() => server = FakeLumenServer());

  Future<Phone> phone(String name) async {
    final p = await Phone.create(server, name);
    addTearDown(p.dispose);
    return p;
  }

  group('LM-103 case 1: crash or OS kill mid-session', () {
    // A finished earlier session: one entry, its card and brief at r1.
    setUp(() => server.seedNotebook(
          _nb,
          userTurns: ['I had a long week.'],
          cardAt: 1,
          briefAt: 1,
        ));

    Future<void> expectCommittedThenCard(Phone device) async {
      expect(server.notebooks[_nb]!.revision, 2);
      expect(server.notebooks[_nb]!.entries.last.text,
          'Priya started at Acme today.');
      expect(server.notebooks[_nb]!.entities.keys, contains('priya'));
      expect(server.ledger.keys, contains((_nb, 'request-t2')));
      expect(await device.journal().listNotebookIdsWithTurns(), isEmpty);
      // The card that follows is for the revision the turn made.
      expect(server.cards[_nb]!.revision, 2);
      expect(server.cardRowsWritten, 1);
      expect(server.cardModelCalls, 1);
      expect(server.brief!.revision, 2);
      expect(server.briefRowsWritten, 1);
      expect(server.briefModelCalls, 1);
    }

    test(
        'LM-103 case 1: a prepared commit in the journal is committed on '
        'relaunch without opening the notebook, and the card follows',
        () async {
      final device = await phone('crash-prepared');
      await _journalPreparedCommit(
          device, server, _turn('t2', 'Priya started at Acme today.'), _priya);
      // Killed here. Nothing reached the server.
      expect(server.commitsApplied, 0);

      // Relaunch: a fresh runner, no notebook open.
      final report = await device.runner().run();

      expect(server.commitsApplied, 1);
      expect(server.extractModelCalls, 0,
          reason: 'the prepared envelope is sent as it was');
      await expectCommittedThenCard(device);
      expect(report.plans, 2, reason: 'it asked again after the commit');
      expect(_outcomes(report), [
        'FinishTurnsStep($_nb) done',
        'CardStep($_nb, r2) done',
        'BriefStep($_nb, r2) done',
        // The phone does not build vectors (case 4).
        'VectorsStep($_nb, 1 missing) serverCatchesUp',
      ]);

      // The launch after that has nothing to do.
      final before = _tally(server);
      await device.runner().run();
      expect(_tally(server), before);
    });

    test(
        'LM-103 case 1: a turn killed before extraction is extracted, '
        'committed and carded on relaunch', () async {
      final device = await phone('crash-raw');
      server.extractions['t2'] = _priya;
      await device
          .journal()
          .persistTurn(_turn('t2', 'Priya started at Acme today.'));

      final report = await device.runner().run();

      expect(server.extractModelCalls, 1);
      expect(server.commitsApplied, 1);
      await expectCommittedThenCard(device);
      expect(report.turnNotebooksFinished, 1);
      expect(report.cardsWritten, 1);

      final before = _tally(server);
      await device.runner().run();
      expect(_tally(server), before);
    });

    test(
        'LM-103 case 1: killed after the commit landed but before the '
        'journal forgot the turn: the ledger replays it, no second entry',
        () async {
      final device = await phone('crash-after-commit');
      final pending = await _journalPreparedCommit(
          device, server, _turn('t2', 'Priya started at Acme today.'), _priya);
      // The commit reached the server; the answer died with the app.
      final checkpoint = (await device.journal().loadCheckpoints(_nb)).single;
      await server.commitNotebook(
        notebookId: _nb,
        expectedRevision: checkpoint.preparedCommit!.expectedRevision,
        requestId: pending.commitRequestId,
        change: checkpoint.preparedCommit!.change,
      );
      expect(server.commitsApplied, 1);

      await device.runner().run();

      expect(server.commitsApplied, 1, reason: 'replayed, not applied again');
      expect(server.notebooks[_nb]!.entries, hasLength(2));
      await expectCommittedThenCard(device);
    });
  });

  group('LM-103 case 2: offline at session end', () {
    // The session's earlier turns committed while online (r2); its card and
    // brief are still at r1. The last turn could not be extracted offline
    // and is still journalled.
    setUp(() => server.seedNotebook(
          _nb,
          userTurns: ['I had a long week.', 'Work was a lot.'],
          cardAt: 1,
          briefAt: 1,
        ));

    Future<Phone> endedOffline(String name) async {
      final device = await phone(name);
      server.extractions['t3'] = _priya;
      await device.journal().persistTurn(_turn('t3', 'Priya helped, though.'));
      device.online = false;
      return device;
    }

    Future<void> expectNothingHappened(Phone device) async {
      expect(server.rowsWritten, 0);
      expect(server.modelCalls, 0);
      expect(server.commitRequestIds, isEmpty);
      expect(server.cards[_nb]!.revision, 1);
      expect(server.brief!.revision, 1);
      // Nothing marked terminal; the turn is still waiting.
      expect(await device.skipStore().read(), isEmpty);
      expect(await device.journal().listNotebookIdsWithTurns(), [_nb]);
    }

    void expectFinishedOnce() {
      expect(server.notebooks[_nb]!.revision, 3);
      expect(server.commitsApplied, 1);
      expect(server.extractModelCalls, 1);
      expect(server.cards[_nb]!.revision, 3);
      expect(server.cardRowsWritten, 1);
      expect(server.cardModelCalls, 1);
      expect(server.brief!.revision, 3);
      expect(server.briefRowsWritten, 1);
      expect(server.briefModelCalls, 1);
    }

    test(
        'LM-103 case 2: nothing is produced offline; on relaunch with the '
        'network back the card and brief are produced exactly once, and a '
        'third run does nothing', () async {
      final device = await endedOffline('offline-relaunch');

      final offline = await device.runner().run();
      expect(offline.loadFailed, isTrue);
      expect(_outcomes(offline), ['FinishTurnsStep($_nb) deferred']);
      await expectNothingHappened(device);

      // The network returns; the app is launched again.
      device.online = true;
      final back = await device.runner().run();
      expect(back.loadFailed, isFalse);
      expect(back.cardsWritten, 1);
      expect(back.briefsWritten, 1);
      expectFinishedOnce();
      expect(await device.journal().listNotebookIdsWithTurns(), isEmpty);

      final before = _tally(server);
      final third = await device.runner().run();
      expect(_tally(server), before);
      expect(third.cardsWritten + third.briefsWritten, 0);
      expectFinishedOnce();
    });

    test(
        'LM-103 case 2: plain resume after a failed leave (status error): '
        'the scheduler finishes the notebook exactly once when the network '
        'is back', () async {
      final device = await endedOffline('offline-resume');

      // The notifier still has the notebook set; only its status changes.
      var status = SessionStatus.ending;
      String? open() => catchUpOwnsNotebook(status) ? _nb : null;
      bool live(String id) => id == _nb && sessionIsLive(status);

      final reports = <CatchUpReport>[];
      final stillRunning = <String>{};
      final scheduler = CatchUpScheduler(
        // A new runner per run, as CatchUpNotifier builds them.
        run: (token) => device
            .runner(
              openNotebookId: open,
              isNotebookLive: live,
              turnsStillRunning: stillRunning,
            )
            .run(token),
        onReport: reports.add,
      );
      scheduler.setUnlocked(true);

      Future<CatchUpReport> resume() async {
        scheduler.request();
        await scheduler.current;
        return reports.last;
      }

      // While the session is still ending, catch-up keeps off it.
      expect(_outcomes(await resume()), ['FinishTurnsStep($_nb) skippedLive']);
      await expectNothingHappened(device);

      // The leave failed offline: status error. Still offline: nothing.
      status = SessionStatus.error;
      final offline = await resume();
      expect(offline.loadFailed, isTrue);
      expect(_outcomes(offline), ['FinishTurnsStep($_nb) deferred']);
      await expectNothingHappened(device);

      // The network is back; the app comes to the foreground.
      device.online = true;
      final back = await resume();
      expect(back.cardsWritten, 1);
      expect(back.briefsWritten, 1);
      expectFinishedOnce();

      // A further resume does nothing.
      final before = _tally(server);
      await resume();
      expect(_tally(server), before);
      expect(scheduler.isRunning, isFalse);
    });
  });

  group('LM-103 case 3: force quit', () {
    // Simulator approximation: the process dying is a cancelled run whose
    // abandoned work never resumes. LM-104 checks this on a device.
    setUp(() => server.seedNotebook(
          _nb,
          userTurns: ['I had a long week.'],
          cardAt: 1,
          briefAt: 1,
        ));

    test(
        'LM-103 case 3: quit after the commit step, before the card: the '
        'next launch finishes everything exactly once', () async {
      final device = await phone('force-quit');
      await device.journal().persistTurn(_turn('t2', 'Priya called.'));
      server.extractions['t2'] = _priya;

      // The quit lands as the runner asks what is left after the commit.
      final token = CatchUpCancelToken();
      final work = UnfinishedWorkService.withRpc(
          (fn, params) => device.net(() => server.rpc(fn, params)));
      var loads = 0;
      final first = await device.runner(loadWork: () async {
        final result = await work.load();
        if (++loads == 2) token.cancel();
        return result;
      }).run(token);

      expect(first.cancelled, isTrue);
      expect(_outcomes(first), ['FinishTurnsStep($_nb) done']);
      expect(server.commitsApplied, 1);
      expect(server.cardRowsWritten + server.briefRowsWritten, 0);
      expect(server.cardModelCalls + server.briefModelCalls, 0);

      // Next launch.
      final next = await device.runner().run();
      expect(next.cardsWritten, 1);
      expect(next.briefsWritten, 1);
      expect(server.commitsApplied, 1);
      expect(server.extractModelCalls, 1);
      expect(server.cards[_nb]!.revision, 2);
      expect(server.cardRowsWritten, 1);
      expect(server.cardModelCalls, 1);
      expect(server.brief!.revision, 2);
      expect(server.briefRowsWritten, 1);
      expect(server.briefModelCalls, 1);

      final before = _tally(server);
      await device.runner().run();
      expect(_tally(server), before);
    });

    test(
        'LM-103 case 3: quit while the card is being written: the next '
        'launch saves one card and the brief', () async {
      final device = await phone('force-quit-card');
      await device.journal().persistTurn(_turn('t2', 'Priya called.'));

      final token = CatchUpCancelToken();
      // The model is writing the card when the app is killed; its answer
      // never comes back to this process.
      server.holdClose = Completer<void>();
      final running = device.runner().run(token);
      await server.closeStarted.future;
      token.cancel();
      final first = await running;
      expect(first.cancelled, isTrue);
      expect(_outcomes(first).last, 'CardStep($_nb, r2) cancelled');
      expect(server.cardRowsWritten, 0);
      server.holdClose = null; // the dead process's request stays pending

      final next = await device.runner().run();
      expect(next.cardsWritten, 1);
      expect(next.briefsWritten, 1);
      expect(server.cardRowsWritten, 1, reason: 'one card saved');
      // The killed process's model call was paid for and never saved; the
      // next launch asked once more. One card, one brief, one commit.
      expect(server.cardModelCalls, 2);
      expect(server.briefRowsWritten, 1);
      expect(server.commitsApplied, 1);
    });
  });

  group('LM-103 case 4: search vectors lagging', () {
    // What is simulated: retrieve-memory and embed-reconcile are the fake
    // server's (the real edge function's missing-vector search is covered
    // by supabase/functions/retrieve-memory/scenarios.test.ts). The app's
    // RetrieveMemoryService is real. The phone builds no vectors today
    // (buildVectors is null): catch-up records the step as "server catches
    // up", and the server's embed-reconcile sweep builds it when poked.
    test(
        'LM-103 case 4: search before the vector exists answers without '
        'error or mention of it; the next catch-up records the vector step '
        'once, the sweep builds it once, and a second catch-up does not',
        () async {
      final device = await phone('vectors');
      // A session that ended normally added Priya: card and brief are at r1,
      // and the embed sweep has not run yet.
      server.seedNotebook(
        _nb,
        userTurns: ['Maya and Priya came over.'],
        entities: [entity('maya', 'Maya'), entity('priya', 'Priya')],
        cardAt: 1,
        briefAt: 1,
      );
      server.vectors.remove((_nb, 'priya'));

      final retrieval = RetrieveMemoryService.withInvoker(
          (body) => device.net(() => server.retrieveMemory(body)));
      final found = await retrieval.retrieveResult(
        query: 'What do I know about Priya?',
        notebookId: _nb,
        scope: RetrievalScope.user,
      );
      expect(found.entityIds, ['priya']);
      expect(found.context, contains('Priya'));
      expect(server.semanticHits, isEmpty, reason: 'no vector yet');
      // What the model (and so the user) hears: nothing about vectors.
      final shown = jsonEncode(memoryToolResult(found));
      expect(
        shown,
        isNot(matches(RegExp(r'vector|embed|missing|index|not (yet )?built',
            caseSensitive: false))),
      );

      final first = await device.runner().run();
      expect(_outcomes(first), ['VectorsStep($_nb, 1 missing) serverCatchesUp']);
      expect(server.embedModelCalls, 0, reason: 'the phone builds none');

      // The server's sweep catches up.
      expect(server.reconcileVectors(), 1);
      expect(server.vectors.keys, contains((_nb, 'priya')));
      expect(server.vectorRowsWritten, 1);

      final second = await device.runner().run();
      expect(second.records, isEmpty, reason: 'no vector step left');
      expect(server.reconcileVectors(), 0, reason: 'not rebuilt');
      expect(server.embedModelCalls, 1);
      expect(server.vectorRowsWritten, 1);

      final again = await retrieval.retrieveResult(
        query: 'What do I know about Priya?',
        notebookId: _nb,
        scope: RetrievalScope.user,
      );
      expect(again.entityIds, ['priya']);
      expect(server.semanticHits, ['priya']);
      expect(server.cardRowsWritten + server.briefRowsWritten, 0);
    });
  });

  group('LM-103 case 5: second iPhone', () {
    // Two simulators in the ticket; here two device fixtures (own journal
    // directory, own skip store, own runners) sharing one server. Phone B's
    // "after phrase entry (LM-89)" is out of scope: same account, plaintext.
    //
    // The copy that tells the user "turns that were only on phone A are
    // lost" belongs to LM-89 / LM-110 and is not built here.
    test(
        "LM-103 case 5: phone B finishes A's server-side steps exactly once; "
        "A's local-only turn never reaches the server", () async {
      // Phone A ended a session: its turns up to r2 committed, the card and
      // brief pending server-side. One more turn is only in A's journal.
      server.seedNotebook(
        _nb,
        userTurns: ['I had a long week.', 'Work was a lot.'],
      );
      final phoneA = await phone('phone-a');
      final aTurn = _turn('a-late', 'One more thing, said only on phone A.');
      await phoneA.journal().persistTurn(aTurn);
      // Phone A is lost: it never runs again.

      final phoneB = await phone('phone-b');
      final report = await phoneB.runner().run();

      expect(_outcomes(report), [
        'CardStep($_nb, r2) done',
        'BriefStep($_nb, r2) done',
      ]);
      expect(server.cards[_nb]!.revision, 2);
      expect(server.cardRowsWritten, 1);
      expect(server.cardModelCalls, 1);
      expect(server.brief!.revision, 2);
      expect(server.briefRowsWritten, 1);
      expect(server.briefModelCalls, 1);

      // A's journalled turn never appears on the server.
      expect(server.notebooks[_nb]!.revision, 2);
      expect(server.commitRequestIds, isNot(contains(aTurn.commitRequestId)));
      expect(server.ledger.keys.map((k) => k.$2),
          isNot(contains(aTurn.commitRequestId)));
      expect(
        server.notebooks[_nb]!.entries.map((e) => e.text),
        isNot(contains(aTurn.transcript)),
      );
      expect(server.extractModelCalls, 0);

      // B cannot see A's journal and leaves it untouched.
      expect(await phoneB.journal().listNotebookIdsWithTurns(), isEmpty);
      final aStill = await phoneA.journal().loadCheckpoints(_nb);
      expect(aStill.single.turn.turnId, 'a-late');
      expect(aStill.single.turn.stage, DurableStage.finalRecorded);

      final before = _tally(server);
      await phoneB.runner().run();
      expect(_tally(server), before);
    });
  });
}

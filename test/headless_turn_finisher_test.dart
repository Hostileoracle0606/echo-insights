import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart'
    show DurableStage, FinalizedTurn, Speaker;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/services/headless_turn_finisher.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/turn_journal_service.dart';

const _notebook = 'notebook-1';

FinalizedTurn _turn({
  String turnId = 'turn-1',
  String requestId = 'request-1',
  Speaker speaker = Speaker.user,
  String transcript = 'I work at Acme with Maya.',
  DurableStage stage = DurableStage.finalRecorded,
  Map<String, dynamic>? extraction,
  int? baseRevision,
}) =>
    FinalizedTurn(
      turnId: turnId,
      sessionId: 'session-1',
      notebookId: _notebook,
      speaker: speaker,
      transcript: transcript,
      transcriptVersion: 1,
      transcriptHash: 'hash-$turnId',
      extractorVersion: 'extractor-1',
      generation: 1,
      commitRequestId: requestId,
      stage: stage,
      extraction: extraction,
      baseRevision: baseRevision,
      finalizedAt: '2026-11-16T09:00:00.000Z',
    );

const _acme = GraphPatch(
  entities: [EntityPatch(name: 'Acme', type: EntityType.organization)],
  relations: [],
  supersedes: [],
);

/// A commit_notebook stand-in with the server's ledger rules: a request id
/// seen before replays its stored result when the change is identical and
/// is refused when it is not; a stale revision is a conflict and writes
/// nothing.
class _FakeServer {
  int revision = 3;
  final List<Map<String, dynamic>> applied = [];
  final Map<String, (String, CommitOutcome)> _ledger = {};
  int commitCalls = 0;
  int snapshotLoads = 0;
  bool loseNextResponse = false;
  bool missing = false;

  /// Runs before each commit is judged: another device writing meanwhile.
  void Function()? beforeCommit;

  Future<CommitOutcome> commit({
    required String notebookId,
    required int expectedRevision,
    required String requestId,
    required NotebookChange change,
  }) async {
    commitCalls += 1;
    beforeCommit?.call();
    if (missing) return const CommitRejected(code: 'notFound');
    final hash = jsonEncode(change.toJson());
    final seen = _ledger[requestId];
    if (seen != null) {
      if (seen.$1 != hash) return const CommitRejected(code: 'requestIdReused');
      return seen.$2;
    }
    if (expectedRevision != revision) {
      return CommitConflict(currentRevision: revision);
    }
    revision += 1;
    applied.add(change.toJson());
    final outcome = CommitCommitted(
      requestId: requestId,
      revision: revision,
      entryId: 'server-entry-$revision',
    );
    _ledger[requestId] = (hash, outcome);
    if (loseNextResponse) {
      loseNextResponse = false;
      throw const SocketException('connection lost after commit');
    }
    return outcome;
  }

  Future<NotebookSnapshot?> snapshot(String notebookId) async {
    snapshotLoads += 1;
    if (missing) return null;
    return NotebookSnapshot(
      notebookId: notebookId,
      revision: revision,
      state: JournalState.empty(),
    );
  }
}

class _FakeExtractor {
  final List<HeadlessExtraction> calls = [];
  Object? failWith;

  Future<GraphPatch> call(HeadlessExtraction request) async {
    calls.add(request);
    final failure = failWith;
    if (failure != null) throw failure;
    return _acme;
  }
}

void main() {
  late Directory directory;
  late TurnJournalService journal;
  late _FakeServer server;
  late _FakeExtractor extractor;
  late HeadlessTurnFinisher finisher;

  HeadlessTurnFinisher build({TurnRedaction redaction = TurnRedaction.none}) =>
      HeadlessTurnFinisher(
        journal: journal,
        commit: server.commit,
        loadSnapshot: server.snapshot,
        extract: extractor.call,
        redaction: redaction,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumen-finisher-');
    journal = TurnJournalService(directoryProvider: () async => directory);
    server = _FakeServer();
    extractor = _FakeExtractor();
    finisher = build();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('(a) a prepared commit', () {
    late FinalizedTurn pending;
    late PreparedTurnCommit prepared;

    setUp(() async {
      pending = _turn(
        stage: DurableStage.commitPending,
        extraction: _acme.toJson(),
        baseRevision: 3,
      );
      prepared = PreparedTurnCommit(
        expectedRevision: 3,
        change: ApplyTurnChange(
          entryText: pending.transcript,
          entryEntityIds: const ['acme'],
          entryRelationIds: const [],
          entities: [
            Entity(
              id: 'acme',
              name: 'Acme',
              type: EntityType.organization,
              metadata: const {},
              mentions: 1,
              firstSeen: DateTime.utc(2026, 11, 16),
              lastSeen: DateTime.utc(2026, 11, 16),
            ),
          ],
          relations: const [],
        ),
        entryId: 'local-entry',
      );
      await journal.persistPreparedCommit(
          turn: pending, preparedCommit: prepared);
    });

    test('is sent as it was, with its request id, and then forgotten',
        () async {
      final result = await finisher.finishNotebook(_notebook);

      expect(result.committedTurnIds, ['turn-1']);
      expect(result.done, isTrue);
      expect(result.revision, 4);
      expect(server.applied.single, prepared.change.toJson());
      expect(server.snapshotLoads, 0, reason: 'no merge needed');
      expect(extractor.calls, isEmpty);
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('sent twice under the same request id makes one commit', () async {
      server.loseNextResponse = true;
      final first = await finisher.finishNotebook(_notebook);
      expect(first.deferredTurnId, 'turn-1');
      expect(await journal.loadCheckpoints(_notebook), hasLength(1),
          reason: 'an unknown outcome keeps the turn');

      final second = await finisher.finishNotebook(_notebook);

      expect(second.committedTurnIds, ['turn-1']);
      expect(server.commitCalls, 2);
      expect(server.applied, hasLength(1), reason: 'the ledger replayed it');
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('a conflict reloads the snapshot and rebases once', () async {
      server.revision = 5; // another device wrote twice meanwhile

      final result = await finisher.finishNotebook(_notebook);

      expect(result.committedTurnIds, ['turn-1']);
      expect(server.snapshotLoads, 1);
      expect(server.applied, hasLength(1));
      final change = server.applied.single;
      expect((change['entry'] as Map)['text'], pending.transcript);
      expect((change['entry'] as Map)['entityIds'], ['acme']);
      expect(server.revision, 6);
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('a second conflict leaves the turn for the next catch-up', () async {
      server.beforeCommit = () => server.revision += 1;

      final result = await finisher.finishNotebook(_notebook);

      expect(result.done, isFalse);
      expect(result.deferredTurnId, 'turn-1');
      expect(server.commitCalls, 2, reason: 'one rebase, then stop');
      expect(server.applied, isEmpty);
      final kept = await journal.loadCheckpoints(_notebook);
      expect(kept.single.turn.commitRequestId, 'request-1');
    });

    test('a refused request id is dropped, as the open notebook does',
        () async {
      // The id already committed different content (the live session got
      // there first with its own envelope).
      await server.commit(
        notebookId: _notebook,
        expectedRevision: 3,
        requestId: 'request-1',
        change: const ApplyTurnChange(
          entryText: 'other',
          entryEntityIds: [],
          entryRelationIds: [],
          entities: [],
          relations: [],
        ),
      );

      final result = await finisher.finishNotebook(_notebook);

      expect(result.rejectedTurnIds, ['turn-1']);
      expect(result.done, isTrue);
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('a notebook this account cannot see is left alone', () async {
      server.missing = true;

      final result = await finisher.finishNotebook(_notebook);

      expect(result.deferredTurnId, 'turn-1');
      expect(await journal.loadCheckpoints(_notebook), hasLength(1),
          reason: 'it may belong to another account on this phone');
    });
  });

  group('(b) an extraction checkpoint without a prepared commit', () {
    setUp(() async {
      await journal.persistTurn(_turn(
        stage: DurableStage.extracted,
        extraction: _acme.toJson(),
      ));
    });

    test('merges on the server snapshot, keeps the envelope, commits',
        () async {
      server.loseNextResponse = true;
      final first = await finisher.finishNotebook(_notebook);
      expect(first.deferredTurnId, 'turn-1');

      // The exact envelope was kept before it was sent.
      final kept = (await journal.loadCheckpoints(_notebook)).single;
      expect(kept.turn.stage, DurableStage.commitPending);
      expect(kept.turn.baseRevision, 3);
      expect(kept.preparedCommit, isNotNull);
      expect(kept.preparedCommit!.expectedRevision, 3);
      expect(kept.preparedCommit!.change.toJson(), server.applied.single);

      final second = await finisher.finishNotebook(_notebook);

      expect(second.committedTurnIds, ['turn-1']);
      expect(server.applied, hasLength(1), reason: 'one commit, replayed');
      expect(server.snapshotLoads, 1, reason: 'the retry did not re-merge');
      expect(extractor.calls, isEmpty);
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('the merge uses the shared merge rules', () async {
      await finisher.finishNotebook(_notebook);

      final change = server.applied.single;
      expect((change['entry'] as Map)['entityIds'], ['acme']);
      final entity = (change['entities'] as List).single as Map;
      expect(entity['id'], 'acme');
      expect(entity['mentions'], 1);
    });

    test('a stale revision on the checkpoint is not used', () async {
      await journal.persistTurn(_turn(
        stage: DurableStage.commitPending,
        extraction: _acme.toJson(),
        baseRevision: 1,
      ));

      final result = await finisher.finishNotebook(_notebook);

      expect(result.committedTurnIds, ['turn-1']);
      expect(server.commitCalls, 1, reason: 'merged at the snapshot revision');
    });
  });

  group('(c) no extraction yet', () {
    setUp(() async {
      await journal.persistTurn(_turn());
    });

    test('extracts once by turn id, then commits; twice is one commit',
        () async {
      server.loseNextResponse = true;
      final first = await finisher.finishNotebook(_notebook);
      expect(first.deferredTurnId, 'turn-1');
      expect(extractor.calls, hasLength(1));
      expect(extractor.calls.single.turnId, 'turn-1');
      expect(extractor.calls.single.notebookId, _notebook);

      final second = await finisher.finishNotebook(_notebook);

      expect(second.committedTurnIds, ['turn-1']);
      expect(extractor.calls, hasLength(1), reason: 'the result was kept');
      expect(server.applied, hasLength(1));
      expect(await journal.loadCheckpoints(_notebook), isEmpty);
    });

    test('the extraction result is checkpointed before the commit', () async {
      // The commit cannot leave the phone this time.
      server.beforeCommit = () => throw const SocketException('offline');

      await finisher.finishNotebook(_notebook);

      final kept = (await journal.loadCheckpoints(_notebook)).single;
      expect(kept.turn.extraction, _acme.toJson());
      expect(kept.preparedCommit, isNotNull);
      expect(server.applied, isEmpty);
    });

    test('a failed extraction leaves the turn for later', () async {
      extractor.failWith = const SocketException('offline');

      final result = await finisher.finishNotebook(_notebook);

      expect(result.deferredTurnId, 'turn-1');
      expect(server.commitCalls, 0);
      final kept = (await journal.loadCheckpoints(_notebook)).single;
      expect(kept.turn.stage, DurableStage.finalRecorded);
    });

    test('what the extractor is sent goes through forget redaction', () async {
      finisher = build(
        redaction: TurnRedaction(
          redact: (text) => text.replaceAll('Maya', 'someone'),
          redactState: (state) => state,
        ),
      );

      await finisher.finishNotebook(_notebook);

      expect(extractor.calls.single.text, 'I work at Acme with someone.');
      // The entry keeps the words as said, as the open notebook does.
      expect((server.applied.single['entry'] as Map)['text'],
          'I work at Acme with Maya.');
    });

    test("Lumen's own turn commits without a model call", () async {
      await journal.forgetNotebook(_notebook);
      await journal.persistTurn(_turn(speaker: Speaker.assistant));

      final result = await finisher.finishNotebook(_notebook);

      expect(result.committedTurnIds, ['turn-1']);
      expect(extractor.calls, isEmpty);
      expect((server.applied.single['entry'] as Map)['entityIds'], isEmpty);
    });
  });

  test('turns commit in journal order and stop at the first that cannot',
      () async {
    await journal.persistTurn(_turn(turnId: 't1', requestId: 'r1'));
    await journal.persistTurn(_turn(
      turnId: 't2',
      requestId: 'r2',
      transcript: 'Maya leads the Atlas project.',
    ));
    await journal.persistTurn(_turn(turnId: 't3', requestId: 'r3'));
    var calls = 0;
    finisher = HeadlessTurnFinisher(
      journal: journal,
      commit: server.commit,
      loadSnapshot: server.snapshot,
      extract: (request) async {
        calls += 1;
        if (request.turnId == 't2') throw const SocketException('offline');
        return _acme;
      },
    );

    final result = await finisher.finishNotebook(_notebook);

    expect(result.committedTurnIds, ['t1']);
    expect(result.deferredTurnId, 't2');
    expect(calls, 2, reason: 't3 waits behind t2');
    final kept = await journal.loadCheckpoints(_notebook);
    expect(kept.map((c) => c.turn.turnId), ['t2', 't3']);
  });

  test('an empty journal does nothing', () async {
    final result = await finisher.finishNotebook(_notebook);
    expect(result.done, isTrue);
    expect(result.committedTurnIds, isEmpty);
    expect(server.commitCalls, 0);
    expect(server.snapshotLoads, 0);
  });
}

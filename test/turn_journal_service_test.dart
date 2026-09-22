import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/turn_journal_service.dart';

FinalizedTurn turn({
  DurableStage stage = DurableStage.finalRecorded,
  Map<String, dynamic>? extraction,
  int? baseRevision,
  String notebookId = 'notebook-1',
}) {
  return FinalizedTurn(
    turnId: 'turn-1',
    sessionId: 'session-1',
    notebookId: notebookId,
    speaker: Speaker.user,
    transcript: 'I work at Acme.',
    transcriptVersion: 2,
    transcriptHash: 'hash-1',
    extractorVersion: 'extractor-1',
    generation: 1,
    commitRequestId: 'request-1',
    stage: stage,
    extraction: extraction,
    baseRevision: baseRevision,
    finalizedAt: '2026-09-17T12:00:00.000Z',
  );
}

void main() {
  late Directory directory;
  late TurnJournalService journal;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumen-turn-journal-');
    journal = TurnJournalService(directoryProvider: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('restores a finalized turn after the service is recreated', () async {
    await journal.persistTurn(turn());

    final restarted =
        TurnJournalService(directoryProvider: () async => directory);
    final restored = await restarted.loadTurns('notebook-1');

    expect(restored, hasLength(1));
    expect(restored.single.turnId, 'turn-1');
    expect(restored.single.stage, DurableStage.finalRecorded);
    expect(restored.single.commitRequestId, 'request-1');
  });

  test('replaces the checkpoint after extraction without changing identity',
      () async {
    await journal.persistTurn(turn());
    await journal.persistTurn(turn(
      stage: DurableStage.extracted,
      extraction: const {
        'entities': [
          {'name': 'Acme', 'type': 'organization'},
        ],
        'relations': <Object>[],
      },
    ));

    final restored = await journal.loadTurns('notebook-1');

    expect(restored, hasLength(1));
    expect(restored.single.stage, DurableStage.extracted);
    expect(restored.single.extraction, isNotNull);
    expect(restored.single.commitRequestId, 'request-1');
  });

  test('restores an uncertain commit with its original request id and revision',
      () async {
    final pending = turn(
      stage: DurableStage.commitPending,
      extraction: const {'entities': <Object>[], 'relations': <Object>[]},
      baseRevision: 12,
    );
    const prepared = PreparedTurnCommit(
      expectedRevision: 12,
      change: ApplyTurnChange(
        entryText: 'I work at Acme.',
        entryEntityIds: <String>[],
        entryRelationIds: <String>[],
        entities: [],
        relations: [],
      ),
      entryId: 'local-entry-1',
    );
    await journal.persistTurn(pending);
    await journal.persistPreparedCommit(
      turn: pending,
      preparedCommit: prepared,
    );

    final restarted =
        TurnJournalService(directoryProvider: () async => directory);
    final restored = await restarted.loadCheckpoints('notebook-1');

    expect(restored.single.turn.stage, DurableStage.commitPending);
    expect(restored.single.turn.baseRevision, 12);
    expect(restored.single.turn.commitRequestId, 'request-1');
    expect(restored.single.preparedCommit!.expectedRevision, 12);
    expect(restored.single.preparedCommit!.entryId, 'local-entry-1');
    expect(restored.single.preparedCommit!.change.toJson(),
        prepared.change.toJson());
  });

  test('confirmed commit cleanup removes the durable checkpoint', () async {
    await journal.persistTurn(turn(stage: DurableStage.commitPending));

    await journal.forgetTurn(notebookId: 'notebook-1', turnId: 'turn-1');

    expect(await journal.loadTurns('notebook-1'), isEmpty);
  });

  test('serializes overlapping stage writes in call order', () async {
    final first = journal.persistTurn(turn());
    final second = journal.persistTurn(turn(
      stage: DurableStage.extracted,
      extraction: const {'entities': <Object>[], 'relations': <Object>[]},
    ));
    await Future.wait([first, second]);

    final restored = await journal.loadTurns('notebook-1');

    expect(restored.single.stage, DurableStage.extracted);
  });

  test('forgetAll removes every notebook\'s transcripts from disk', () async {
    await journal.persistTurn(turn());
    await journal.persistTurn(turn(notebookId: 'notebook-2'));
    final journalDir = Directory('${directory.path}/turn-journal-v1');
    expect(journalDir.listSync(), hasLength(2));

    await journal.forgetAll();

    expect(await journalDir.exists(), isFalse);
    expect(await journal.loadTurns('notebook-1'), isEmpty);
    expect(await journal.loadTurns('notebook-2'), isEmpty);
  });

  test('forgetAll is a no-op when nothing was ever journaled', () async {
    await journal.forgetAll();
    expect(await journal.loadTurns('notebook-1'), isEmpty);
  });
}

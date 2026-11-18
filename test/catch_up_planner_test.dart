import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/catch_up_service.dart';
import 'package:lumen/services/unfinished_work_service.dart';

void main() {
  group('UnfinishedWork.fromJson', () {
    test('reads ids and numbers from get_unfinished_work', () {
      final work = UnfinishedWork.fromJson({
        'cards': [
          {'notebookId': 'n1', 'revision': 4, 'cardRevision': 2},
          {'notebookId': 'n2', 'revision': 3, 'cardRevision': null},
          {'notebookId': 'n3', 'revision': 5, 'cardRevision': 5, 'draft': true},
        ],
        'briefs': [
          {'notebookId': 'n1', 'revision': 4},
        ],
        'vectors': [
          {'notebookId': 'n2', 'entityCount': 7, 'missing': 3},
        ],
        'erase': [
          {'id': 'job-1', 'nextBatch': 2, 'rewritten': 40},
        ],
        'truncated': true,
      });

      expect(work.cards, const [
        UnfinishedCard(notebookId: 'n1', revision: 4, cardRevision: 2),
        UnfinishedCard(notebookId: 'n2', revision: 3),
        UnfinishedCard(
            notebookId: 'n3', revision: 5, cardRevision: 5, draft: true),
      ]);
      expect(
          work.briefs, const [UnfinishedBrief(notebookId: 'n1', revision: 4)]);
      expect(work.vectors, const [
        UnfinishedVectors(notebookId: 'n2', entityCount: 7, missing: 3),
      ]);
      expect(work.erase, const [
        UnfinishedErase(jobId: 'job-1', nextBatch: 2, rewritten: 40),
      ]);
      expect(work.truncated, isTrue);
    });

    test('a missing or malformed list reads as empty', () {
      final work = UnfinishedWork.fromJson({
        'cards': 'nope',
        'vectors': [
          {'notebookId': 'n1'}, // no counts: dropped
          'junk',
        ],
      });
      expect(work.cards, isEmpty);
      expect(work.briefs, isEmpty);
      expect(work.vectors, isEmpty);
      expect(work.erase, isEmpty);
      expect(work.truncated, isFalse);
      expect(UnfinishedWork.fromJson(null).isEmpty, isTrue);
    });

    test('the service calls get_unfinished_work with no parameters', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final service = UnfinishedWorkService.withRpc((function, params) async {
        calls.add((function, params));
        return {
          'cards': [
            {'notebookId': 'n1', 'revision': 1, 'cardRevision': null},
          ],
        };
      });

      final work = await service.load();

      expect(calls.single.$1, 'get_unfinished_work');
      expect(calls.single.$2, isEmpty);
      expect(work.cards.single.notebookId, 'n1');
    });
  });

  group('CatchUpPlanner.plan', () {
    test('nothing to do makes an empty plan', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: 'open',
        journalNotebookIds: const [],
        serverWork: UnfinishedWork.empty,
      );
      expect(plan.steps, isEmpty);
      expect(plan.isEmpty, isTrue);
      expect(plan.replanAfterTurns, isFalse);
    });

    test('the open notebook goes first: turns, then card, brief, vectors', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: 'open',
        journalNotebookIds: const ['other', 'open'],
        serverWork: const UnfinishedWork(
          cards: [
            UnfinishedCard(notebookId: 'other', revision: 9),
            UnfinishedCard(notebookId: 'open', revision: 4, cardRevision: 3),
          ],
          briefs: [UnfinishedBrief(notebookId: 'open', revision: 4)],
          vectors: [
            UnfinishedVectors(notebookId: 'open', entityCount: 5, missing: 2),
          ],
        ),
      );

      expect(plan.steps.take(4).toList(), const [
        FinishTurnsStep(notebookId: 'open'),
        CardStep(notebookId: 'open', revision: 4, cardRevision: 3),
        BriefStep(notebookId: 'open', revision: 4),
        VectorsStep(notebookId: 'open', entityCount: 5, missing: 2),
      ]);
      expect(plan.steps.skip(4).toList(), const [
        FinishTurnsStep(notebookId: 'other'),
        CardStep(notebookId: 'other', revision: 9),
      ]);
    });

    test('other notebooks follow newest first, each kept together', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: null,
        // Newest turn first, as listNotebookIdsWithTurns returns them.
        journalNotebookIds: const ['j1', 'j2'],
        serverWork: const UnfinishedWork(
          // Server lists come newest first too.
          cards: [
            UnfinishedCard(notebookId: 'c1', revision: 2),
            UnfinishedCard(notebookId: 'j2', revision: 6, cardRevision: 5),
            UnfinishedCard(notebookId: 'c2', revision: 1),
          ],
          briefs: [UnfinishedBrief(notebookId: 'c1', revision: 2)],
          vectors: [
            UnfinishedVectors(notebookId: 'v1', entityCount: 1, missing: 1),
            UnfinishedVectors(notebookId: 'c2', entityCount: 4, missing: 4),
          ],
        ),
      );

      expect(plan.steps, const [
        FinishTurnsStep(notebookId: 'j1'),
        FinishTurnsStep(notebookId: 'j2'),
        CardStep(notebookId: 'j2', revision: 6, cardRevision: 5),
        CardStep(notebookId: 'c1', revision: 2),
        BriefStep(notebookId: 'c1', revision: 2),
        CardStep(notebookId: 'c2', revision: 1),
        VectorsStep(notebookId: 'c2', entityCount: 4, missing: 4),
        VectorsStep(notebookId: 'v1', entityCount: 1, missing: 1),
      ]);
    });

    test('erase batches come last, in server order', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: 'open',
        journalNotebookIds: const ['open'],
        serverWork: const UnfinishedWork(
          erase: [
            UnfinishedErase(jobId: 'job-a', nextBatch: 1, rewritten: 0),
            UnfinishedErase(jobId: 'job-b', nextBatch: 3, rewritten: 600),
          ],
          vectors: [
            UnfinishedVectors(notebookId: 'v1', entityCount: 1, missing: 1),
          ],
        ),
      );

      expect(plan.steps, const [
        FinishTurnsStep(notebookId: 'open'),
        VectorsStep(notebookId: 'v1', entityCount: 1, missing: 1),
        EraseStep(jobId: 'job-a', nextBatch: 1),
        EraseStep(jobId: 'job-b', nextBatch: 3),
      ]);
    });

    test('a draft card at the current revision is still a card step', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: null,
        journalNotebookIds: const [],
        serverWork: const UnfinishedWork(cards: [
          UnfinishedCard(
              notebookId: 'n', revision: 3, cardRevision: 3, draft: true),
        ]),
      );
      expect(plan.steps, const [
        CardStep(notebookId: 'n', revision: 3, cardRevision: 3, draft: true),
      ]);
    });

    test('repeated journal ids plan one turns step each', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: null,
        journalNotebookIds: const ['a', 'a', 'b'],
        serverWork: UnfinishedWork.empty,
      );
      expect(plan.steps, const [
        FinishTurnsStep(notebookId: 'a'),
        FinishTurnsStep(notebookId: 'b'),
      ]);
    });

    test('says to replan after turns, and carries truncation', () {
      final withTurns = CatchUpPlanner.plan(
        openNotebookId: null,
        journalNotebookIds: const ['a'],
        serverWork: const UnfinishedWork(truncated: true),
      );
      expect(withTurns.replanAfterTurns, isTrue,
          reason: 'committed turns move the revision a card is made for');
      expect(withTurns.truncated, isTrue);

      final serverOnly = CatchUpPlanner.plan(
        openNotebookId: null,
        journalNotebookIds: const [],
        serverWork: const UnfinishedWork(
            cards: [UnfinishedCard(notebookId: 'a', revision: 1)]),
      );
      expect(serverOnly.replanAfterTurns, isFalse);
    });

    test('steps for one notebook are listed by notebook id', () {
      final plan = CatchUpPlanner.plan(
        openNotebookId: null,
        journalNotebookIds: const ['a'],
        serverWork: const UnfinishedWork(
          cards: [UnfinishedCard(notebookId: 'a', revision: 2)],
          erase: [UnfinishedErase(jobId: 'j', nextBatch: 1, rewritten: 0)],
        ),
      );
      expect(plan.stepsFor('a'), const [
        FinishTurnsStep(notebookId: 'a'),
        CardStep(notebookId: 'a', revision: 2),
      ]);
      expect(plan.steps.last.notebookId, isNull);
    });
  });
}

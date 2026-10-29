// Unit-level coverage for the notebook-commit wire contract: pure JSON
// marshaling, no live Supabase client (the actual RPC round trip is proven
// against real Postgres by supabase/tests/database/notebook_commit_test.sql
// — 31 pgTAP assertions covering every CommitOutcome status, concurrency,
// idempotency, and rollback). What's tested here is the boundary each
// client owns: does our JSON match what the server produces/expects.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/notebook_commit_service.dart';

void main() {
  group('Relation JSON — the original bug, as a regression test', () {
    test('round-trips source/target, never source_id/target_id', () {
      final relation = Relation(
        id: 'maya__works_on__atlas',
        source: 'maya',
        target: 'atlas',
        label: 'works_on',
        metadata: const {},
        createdAt: DateTime.utc(2026, 8, 21),
      );

      final json = relation.toJson();
      expect(json['source'], 'maya');
      expect(json['target'], 'atlas');
      expect(json.containsKey('source_id'), isFalse);
      expect(json.containsKey('target_id'), isFalse);

      // This is exactly the shape get_notebook_snapshot returns (camelCase,
      // source/target already translated server-side from source_id/target_id).
      final parsed = Relation.fromJson({
        'id': 'maya__works_on__atlas',
        'source': 'maya',
        'target': 'atlas',
        'label': 'works_on',
        'metadata': <String, dynamic>{},
        'createdAt': '2026-08-21T00:00:00.000Z',
        'supersededAt': null,
      });
      expect(parsed.source, 'maya');
      expect(parsed.target, 'atlas');
    });
  });

  group('Entity JSON — camelCase, matching the RPC contract', () {
    test('round-trips firstSeen/lastSeen as camelCase keys', () {
      final entity = Entity(
        id: 'maya',
        name: 'Maya',
        type: EntityType.person,
        metadata: const {},
        mentions: 3,
        firstSeen: DateTime.utc(2026, 8, 21),
        lastSeen: DateTime.utc(2026, 8, 22),
      );
      final json = entity.toJson();
      expect(json['firstSeen'], isNotNull);
      expect(json['lastSeen'], isNotNull);
      expect(json.containsKey('first_seen'), isFalse);
      expect(json['type'], 'person');
    });
  });

  group('NotebookChange.toJson', () {
    test('applyTurn carries entry/entities/relations and omits null optionals',
        () {
      final change = ApplyTurnChange(
        entryText: 'Had coffee with Maya.',
        entryEntityIds: const ['maya'],
        entryRelationIds: const [],
        entities: [
          Entity(
            id: 'maya',
            name: 'Maya',
            type: EntityType.person,
            metadata: const {},
            mentions: 1,
            firstSeen: DateTime.utc(2026, 8, 21),
            lastSeen: DateTime.utc(2026, 8, 21),
          ),
        ],
        relations: const [],
      );
      final json = change.toJson();
      expect(json['kind'], 'applyTurn');
      expect(json['entry'], {
        'text': 'Had coffee with Maya.',
        'entityIds': ['maya'],
        'relationIds': <String>[],
      });
      expect((json['entities'] as List).single['id'], 'maya');
      expect(json.containsKey('followUp'), isFalse);
      expect(json.containsKey('askedQuestion'), isFalse);
    });

    test('applyTurn includes followUp/askedQuestion when present', () {
      const change = ApplyTurnChange(
        entryText: 'x',
        entryEntityIds: [],
        entryRelationIds: [],
        entities: [],
        relations: [],
        followUp: FollowUpContent(
          question: 'When is the launch?',
          reason: 'thin coverage',
          targetEntityIds: ['atlas'],
        ),
        askedQuestion: AskedQuestionContent(
          question: 'When is the launch?',
          targetEntityIds: ['atlas'],
        ),
      );
      final json = change.toJson();
      expect(json['followUp'], {
        'question': 'When is the launch?',
        'reason': 'thin coverage',
        'targetEntityIds': ['atlas'],
      });
      expect(json['askedQuestion'], {
        'question': 'When is the launch?',
        'targetEntityIds': ['atlas'],
      });
    });

    // commit_notebook's entity upsert tests `value->'questions' is null`, which
    // is false for a JSON null, so `"questions": null` reached
    // jsonb_array_elements_text and raised 22023 "cannot extract elements from
    // a scalar" — surfaced only as commitFailed, losing every new entity that
    // had no questions. Absent, not null, is how "none" travels on the wire.
    test('applyTurn omits null entity/relation fields instead of sending null',
        () {
      final change = ApplyTurnChange(
        entryText: 'Had coffee with Maya about Atlas.',
        entryEntityIds: const ['maya', 'atlas'],
        entryRelationIds: const ['maya__works_on__atlas'],
        entities: [
          Entity(
            id: 'maya',
            name: 'Maya',
            type: EntityType.person,
            metadata: const {},
            mentions: 1,
            firstSeen: DateTime.utc(2026, 8, 21),
            lastSeen: DateTime.utc(2026, 8, 21),
          ),
          Entity(
            id: 'atlas',
            name: 'Atlas',
            type: EntityType.project,
            description: 'A side project',
            metadata: const {},
            mentions: 1,
            firstSeen: DateTime.utc(2026, 8, 21),
            lastSeen: DateTime.utc(2026, 8, 21),
            questions: const ['When does it launch?'],
          ),
        ],
        relations: [
          Relation(
            id: 'maya__works_on__atlas',
            source: 'maya',
            target: 'atlas',
            label: 'works_on',
            metadata: const {},
            createdAt: DateTime.utc(2026, 8, 21),
          ),
        ],
      );
      final json = change.toJson();
      final entities = (json['entities'] as List).cast<Map<String, dynamic>>();
      final relations =
          (json['relations'] as List).cast<Map<String, dynamic>>();

      expect(entities[0].containsKey('questions'), isFalse);
      expect(entities[0].containsKey('description'), isFalse);
      expect(entities[0].values, isNot(contains(null)));
      expect(entities[1]['questions'], ['When does it launch?']);
      expect(entities[1]['description'], 'A side project');
      expect(relations.single.containsKey('supersededAt'), isFalse);
      expect(relations.single.values, isNot(contains(null)));
    });

    test('answerFollowUp and clearNotebook serialize to their minimal shape',
        () {
      expect(const AnswerFollowUpChange('fu-1').toJson(),
          {'kind': 'answerFollowUp', 'followUpId': 'fu-1'});
      expect(const ClearNotebookChange().toJson(), {'kind': 'clearNotebook'});
    });
  });

  group('CommitOutcome.fromJson', () {
    test('parses committed', () {
      final outcome = CommitOutcome.fromJson({
        'status': 'committed',
        'requestId': 'r1',
        'revision': 3,
        'ids': {'entryId': 'e1', 'followUpId': null},
      });
      expect(outcome, isA<CommitCommitted>());
      final committed = outcome as CommitCommitted;
      expect(committed.revision, 3);
      expect(committed.entryId, 'e1');
      expect(committed.followUpId, isNull);
    });

    test('parses conflict', () {
      final outcome = CommitOutcome.fromJson(
          {'status': 'conflict', 'currentRevision': 7});
      expect(outcome, isA<CommitConflict>());
      expect((outcome as CommitConflict).currentRevision, 7);
    });

    test('parses rejected', () {
      final outcome = CommitOutcome.fromJson(
          {'status': 'rejected', 'code': 'invalidChange'});
      expect(outcome, isA<CommitRejected>());
      expect((outcome as CommitRejected).code, 'invalidChange');
    });
  });

  group('NotebookSnapshot.fromJson', () {
    test('reshapes a raw snapshot into entries/entities/relations/followUps',
        () {
      final snapshot = NotebookSnapshot.fromJson({
        'notebookId': 'nb-1',
        'revision': 5,
        'state': {
          'entries': [
            {
              'id': 'e1',
              'text': 'hi',
              'createdAt': '2026-08-21T00:00:00.000Z',
              'entityIds': ['maya'],
              'relationIds': <String>[],
            }
          ],
          'entities': {
            'maya': {
              'id': 'maya',
              'name': 'Maya',
              'type': 'person',
              'metadata': <String, dynamic>{},
              'mentions': 1,
              'firstSeen': '2026-08-21T00:00:00.000Z',
              'lastSeen': '2026-08-21T00:00:00.000Z',
            }
          },
          'relations': <String, dynamic>{},
          'followUps': <dynamic>[],
        },
      });

      expect(snapshot.notebookId, 'nb-1');
      expect(snapshot.revision, 5);
      expect(snapshot.state.entries.single.id, 'e1');
      expect(snapshot.state.entities['maya']?.name, 'Maya');
      expect(snapshot.state.relations, isEmpty);
    });

    test('defensively coalesces null aggregate fields to empty collections',
        () {
      final snapshot = NotebookSnapshot.fromJson({
        'notebookId': 'nb-1',
        'revision': 0,
        'state': {
          'entries': null,
          'entities': null,
          'relations': null,
          'followUps': null,
        },
      });
      expect(snapshot.state.entries, isEmpty);
      expect(snapshot.state.entities, isEmpty);
      expect(snapshot.state.relations, isEmpty);
      expect(snapshot.state.followUps, isEmpty);
    });
  });
}

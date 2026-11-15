// LM-29 wire contract: the two memory-control RPCs and the snapshot fields.
// The RPCs themselves are proven against Postgres by
// supabase/tests/database/memory_control_test.sql.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';

void main() {
  group('MemoryControlService', () {
    late List<(String, Map<String, dynamic>)> calls;
    late Object? response;
    late MemoryControlService service;

    setUp(() {
      calls = [];
      response = null;
      service = MemoryControlService.withRpc((fn, params) async {
        calls.add((fn, params));
        return response;
      });
    });

    test('editDescription calls edit_entity_description', () async {
      response = {'updatedNotebooks': 2};

      final updated = await service.editDescription('maya', 'My friend.');

      expect(updated, 2);
      expect(calls.single.$1, 'edit_entity_description');
      expect(calls.single.$2, {'p_entity_id': 'maya', 'p_text': 'My friend.'});
    });

    test('previewForget and forgetEntity call their RPCs', () async {
      response = {
        'notebooks': 2,
        'relations': 3,
        'followUps': 1,
        'askedQuestions': 0,
        'cards': 1,
        'briefDeleted': true,
      };

      final preview = await service.previewForget('priya');
      expect(calls.last.$1, 'forget_entity_preview');
      expect(calls.last.$2, {'p_entity_id': 'priya'});
      expect(preview.notebooks, 2);
      expect(preview.relations, 3);
      expect(preview.cards, 1);
      expect(preview.briefDeleted, isTrue);

      final done = await service.forgetEntity('priya');
      expect(calls.last.$1, 'forget_entity');
      // Off: the one-argument RPC, as every older build calls it.
      expect(calls.last.$2, {'p_entity_id': 'priya'});
      expect(done.followUps, 1);
    });

    test('forgetEntity with eraseTranscripts queues an erase job', () async {
      response = {
        'notebooks': 1,
        'transcriptPassages': 500,
        'transcriptPassagesCapped': true,
        'eraseAvailable': true,
      };
      final preview = await service.previewForget('maya-chen');
      expect(preview.transcriptPassages, 500);
      expect(preview.transcriptPassagesCapped, isTrue);
      expect(preview.eraseAvailable, isTrue);

      response = {'notebooks': 1, 'eraseJobId': 'job-1'};
      final done =
          await service.forgetEntity('maya-chen', eraseTranscripts: true);
      expect(calls.last.$1, 'forget_entity');
      expect(calls.last.$2,
          {'p_entity_id': 'maya-chen', 'p_erase_transcripts': true});
      expect(done.eraseJobId, 'job-1');
    });

    test('an older server: no erase offered, no job', () async {
      response = {'notebooks': 1};
      final preview = await service.previewForget('maya-chen');
      expect(preview.eraseAvailable, isFalse);
      expect(preview.transcriptPassagesCapped, isFalse);
      expect(preview.eraseJobId, isNull);
    });

    test('eraseSample reads before and after passages', () async {
      response = {
        'available': true,
        'passages': [
          {'before': 'Maya Chen called.', 'after': 'someone called.'},
        ],
      };
      final sample = await service.eraseSample('maya-chen');
      expect(calls.last.$1, 'forget_erase_sample');
      expect(calls.last.$2, {'p_entity_id': 'maya-chen', 'p_limit': 3});
      expect(sample.single.before, 'Maya Chen called.');
      expect(sample.single.after, 'someone called.');
    });

    test('eraseStep runs one bounded batch of a job', () async {
      response = {
        'rewritten': 4,
        'total': 10,
        'remaining': 1200,
        'finished': false,
      };
      final step = await service.eraseStep('job-1');
      expect(calls.last.$1, 'forget_erase_step');
      expect(calls.last.$2, {'p_job_id': 'job-1', 'p_batch': 300});
      expect(step.total, 10);
      expect(step.remaining, 1200);
      expect(step.finished, isFalse);
    });

    test('pendingErases lists job ids', () async {
      response = [
        {'id': 'job-1', 'rewritten': 3},
      ];
      expect(await service.pendingErases(), ['job-1']);
      expect(calls.last.$1, 'forget_erase_pending');
    });

    test('removeEntity calls remove_entity', () async {
      response = {'removedFrom': 3};

      final removed = await service.removeEntity('priya');

      expect(removed, 3);
      expect(calls.single.$1, 'remove_entity');
      expect(calls.single.$2, {'p_entity_id': 'priya'});
    });
  });

  group('NotebookSnapshot', () {
    Map<String, dynamic> snapshotJson() => {
          'notebookId': 'nb',
          'revision': 4,
          'state': {
            'entries': <dynamic>[],
            'entities': {
              'maya': {
                'id': 'maya',
                'name': 'Maya',
                'type': 'person',
                'description': 'My friend.',
                'descriptionSource': 'user',
                'metadata': <String, dynamic>{},
                'mentions': 1,
                'firstSeen': '2026-10-23T00:00:00Z',
                'lastSeen': '2026-10-23T00:00:00Z',
                'questions': null,
              },
            },
            'relations': <String, dynamic>{},
            'followUps': <dynamic>[],
            'askedQuestions': <dynamic>[],
          },
        };

    test('reads descriptionSource', () {
      final snapshot = NotebookSnapshot.fromJson(snapshotJson());

      expect(snapshot.state.entities['maya']!.descriptionSource, 'user');
    });
  });
}

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

    test('removeEntity calls remove_entity', () async {
      response = {'removedFrom': 3};

      final removed = await service.removeEntity('priya');

      expect(removed, 3);
      expect(calls.single.$1, 'remove_entity');
      expect(calls.single.$2, {'p_entity_id': 'priya'});
    });
  });

  group('NotebookSnapshot', () {
    Map<String, dynamic> snapshotJson({List<String>? suppressed}) => {
          'notebookId': 'nb',
          'revision': 4,
          if (suppressed != null) 'suppressedEntityIds': suppressed,
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

    test('reads suppressedEntityIds and descriptionSource', () {
      final snapshot =
          NotebookSnapshot.fromJson(snapshotJson(suppressed: ['priya']));

      expect(snapshot.suppressedEntityIds, {'priya'});
      expect(snapshot.state.entities['maya']!.descriptionSource, 'user');
    });

    test('has no suppressed ids when the server sends none', () {
      expect(NotebookSnapshot.fromJson(snapshotJson()).suppressedEntityIds,
          isEmpty);
    });
  });
}

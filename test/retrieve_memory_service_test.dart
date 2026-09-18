import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/retrieve_memory_service.dart';

void main() {
  final now = DateTime.utc(2026, 6, 13, 9);

  Map<String, dynamic> fixture(String name) => jsonDecode(
        File('contracts/fixtures/$name').readAsStringSync(),
      ) as Map<String, dynamic>;

  test('parses the shared retrieve-memory v1 success fixture', () {
    final result = MemoryRetrieval.fromData(
      fixture('retrieve-memory-v1.success.json'),
    );

    expect(result.context, 'Maya works on Project Atlas.');
    expect(result.entityIds, ['maya', 'project-atlas']);
  });

  test('parses the shared retrieve-memory v1 empty fixture', () {
    final result = MemoryRetrieval.fromData(
      fixture('retrieve-memory-v1.empty.json'),
    );

    expect(result.context, isEmpty);
    expect(result.entityIds, isEmpty);
  });

  test('rejects legacy, future, and malformed retrieval responses', () {
    expect(
      () => MemoryRetrieval.fromData({
        'context': 'legacy',
        'entityIds': <String>[],
      }),
      throwsFormatException,
    );
    expect(
      () => MemoryRetrieval.fromData({
        'version': 2,
        'context': 'future',
        'entityIds': <String>[],
      }),
      throwsFormatException,
    );
    expect(
      () => MemoryRetrieval.fromData({
        'version': 1,
        'context': 'bad',
        'entityIds': ['maya', 4],
      }),
      throwsFormatException,
    );
  });

  test('stateToGraphloop emits graphloop camelCase keys, not snake_case', () {
    final state = JournalState(
      entries: [
        JournalEntry(
          id: 'e1',
          text: 'Maya works on Atlas.',
          createdAt: now,
          entityIds: const ['maya', 'atlas'],
          relationIds: const ['r1'],
        ),
      ],
      entities: {
        'maya': Entity(
          id: 'maya',
          name: 'Maya',
          type: EntityType.person,
          metadata: const {},
          mentions: 2,
          firstSeen: now,
          lastSeen: now,
          questions: const ['Who is Maya?'],
        ),
      },
      relations: {
        'r1': Relation(
          id: 'r1',
          source: 'maya',
          target: 'atlas',
          label: 'works_on',
          metadata: const {},
          createdAt: now,
          supersededAt: now,
        ),
      },
      followUps: const [],
    );

    final out = stateToGraphloop(state);

    // Entities keyed by id; camelCase timestamp fields.
    final maya = (out['entities'] as Map)['maya'] as Map;
    expect(maya['firstSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya['lastSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya.containsKey('first_seen'), isFalse);
    expect(maya['type'], 'person');

    // Relations: camelCase createdAt / supersededAt.
    final r1 = (out['relations'] as Map)['r1'] as Map;
    expect(r1['createdAt'], '2026-06-13T09:00:00.000Z');
    expect(r1['supersededAt'], '2026-06-13T09:00:00.000Z');
    expect(r1.containsKey('superseded_at'), isFalse);

    // Entries: list with camelCase entityIds / relationIds.
    final e1 = (out['entries'] as List).first as Map;
    expect(e1['entityIds'], ['maya', 'atlas']);
    expect(e1['relationIds'], ['r1']);
    expect(e1.containsKey('entity_ids'), isFalse);

    // followUps dropped.
    expect(out.containsKey('followUps'), isFalse);
  });
}

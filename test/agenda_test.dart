import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/agenda.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';

void main() {
  final now = DateTime.utc(2026, 6, 13);

  Entity entity(
    String id,
    String name, {
    List<String>? questions,
    int mentions = 1,
  }) =>
      Entity(
        id: id,
        name: name,
        type: EntityType.project,
        metadata: const {},
        mentions: mentions,
        firstSeen: now,
        lastSeen: now,
        questions: questions,
      );

  Relation relation(String source, String label, String target) => Relation(
        id: '${source}__${label}__$target',
        source: source,
        target: target,
        label: label,
        metadata: const {},
        createdAt: now,
      );

  test('single-mention entity is classified as thin', () {
    final agenda = buildAgenda(
      JournalState(
        entries: [
          JournalEntry(
            id: 'e1',
            text: 'Atlas.',
            createdAt: now,
            entityIds: const ['atlas'],
            relationIds: const [],
          ),
        ],
        entities: {'atlas': entity('atlas', 'Atlas')},
        relations: const {},
        followUps: const [],
      ),
    );

    expect(agenda.thinEntities, contains('Atlas'));
  });

  test('fresh relation scores at least two as uncertain', () {
    final r = relation('maya', 'works_on', 'atlas');
    final agenda = buildAgenda(
      JournalState(
        entries: [
          JournalEntry(
            id: 'e1',
            text: 'Maya works on Atlas.',
            createdAt: now,
            entityIds: const ['maya', 'atlas'],
            relationIds: [r.id],
          ),
        ],
        entities: {
          'maya': entity('maya', 'Maya'),
          'atlas': entity('atlas', 'Atlas'),
        },
        relations: {r.id: r},
        followUps: const [],
      ),
    );

    expect(agenda.uncertainRelations.single.score, greaterThanOrEqualTo(2));
  });

  test('bridge candidate appears when two entities share a neighbor', () {
    final r1 = relation('maya', 'works_on', 'atlas');
    final r2 = relation('sam', 'works_on', 'atlas');
    final agenda = buildAgenda(
      JournalState(
        entries: [
          JournalEntry(
            id: 'e1',
            text: 'Maya and Sam both orbit Atlas.',
            createdAt: now,
            entityIds: const ['maya', 'sam', 'atlas'],
            relationIds: [r1.id, r2.id],
          ),
        ],
        entities: {
          'maya': entity('maya', 'Maya'),
          'sam': entity('sam', 'Sam'),
          'atlas': entity('atlas', 'Atlas'),
        },
        relations: {r1.id: r1, r2.id: r2},
        followUps: const [],
      ),
    );

    expect(agenda.bridgeCandidates, contains(('Maya', 'Sam')));
  });

  test('open questions are populated from entity question backlogs', () {
    final agenda = buildAgenda(
      JournalState(
        entries: const [],
        entities: {
          'atlas': entity(
            'atlas',
            'Atlas',
            questions: ['What problem is Atlas solving?'],
          ),
        },
        relations: const {},
        followUps: const [],
      ),
    );

    expect(agenda.openQuestions.single.entity, 'Atlas');
    expect(
        agenda.openQuestions.single.question, 'What problem is Atlas solving?');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/merge.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';

void main() {
  test('new entity appears and re-mention increments', () {
    final first = merge(
      JournalState.empty(),
      'Maya joined Atlas.',
      const GraphPatch(
        entities: [EntityPatch(name: 'Maya', type: EntityType.person)],
        relations: [],
        supersedes: [],
      ),
    ).next;

    expect(first.entities['maya']?.mentions, 1);

    final second = merge(
      first,
      'Maya followed up.',
      const GraphPatch(
        entities: [EntityPatch(name: 'Maya', type: EntityType.person)],
        relations: [],
        supersedes: [],
      ),
    ).next;

    expect(second.entities['maya']?.mentions, 2);
  });

  test('supersede stamps relation and re-assertion clears it', () {
    final withRelation = merge(
      JournalState.empty(),
      'Maya works on Atlas.',
      const GraphPatch(
        entities: [
          EntityPatch(name: 'Maya', type: EntityType.person),
          EntityPatch(name: 'Atlas', type: EntityType.project),
        ],
        relations: [
          RelationPatch(
            source: 'Maya',
            target: 'Atlas',
            label: 'works_on',
          ),
        ],
        supersedes: [],
      ),
    ).next;
    const relationId = 'maya__works_on__atlas';

    final superseded = merge(
      withRelation,
      'Maya is not on Atlas.',
      const GraphPatch(
        entities: [],
        relations: [],
        supersedes: [relationId],
      ),
    ).next;

    expect(superseded.relations[relationId]?.supersededAt, isNotNull);

    final healed = merge(
      superseded,
      'Actually Maya works on Atlas.',
      const GraphPatch(
        entities: [
          EntityPatch(name: 'Maya', type: EntityType.person),
          EntityPatch(name: 'Atlas', type: EntityType.project),
        ],
        relations: [
          RelationPatch(
            source: 'Maya',
            target: 'Atlas',
            label: 'works_on',
          ),
        ],
        supersedes: [],
      ),
    ).next;

    expect(healed.relations[relationId]?.supersededAt, isNull);
  });

  test('questions dedupe newest-first and cap at eight', () {
    var state = merge(
      JournalState.empty(),
      'Project Atlas came up.',
      const GraphPatch(
        entities: [
          EntityPatch(
            name: 'Project Atlas',
            type: EntityType.project,
            questions: ['What is Atlas?', 'Who is on it?'],
          ),
        ],
        relations: [],
        supersedes: [],
      ),
    ).next;

    state = merge(
      state,
      'More about Project Atlas.',
      const GraphPatch(
        entities: [
          EntityPatch(
            name: 'Project Atlas',
            type: EntityType.project,
            questions: [
              'Who is on it?',
              'What problem does it solve?',
              'What is the deadline?',
              'What changed recently?',
              'What is risky?',
              'Who owns it?',
              'What is done?',
              'What is next?',
              'What is extra?',
            ],
          ),
        ],
        relations: [],
        supersedes: [],
      ),
    ).next;

    final questions = state.entities['project-atlas']?.questions;
    expect(questions, hasLength(8));
    expect(questions?.first, 'Who is on it?');
    expect(questions, contains('What problem does it solve?'));
    expect(questions?.where((q) => q == 'Who is on it?'), hasLength(1));
  });

  test('relation backfill bumps endpoint mention counts from prior state', () {
    final now = DateTime.utc(2026, 6, 13);
    final state = JournalState(
      entries: [
        JournalEntry(
          id: 'entry-1',
          text: 'Maya and Atlas existed already.',
          createdAt: now,
          entityIds: const ['maya', 'atlas'],
          relationIds: const [],
        ),
      ],
      entities: {
        'maya': Entity(
          id: 'maya',
          name: 'Maya',
          type: EntityType.person,
          metadata: const {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
        ),
        'atlas': Entity(
          id: 'atlas',
          name: 'Atlas',
          type: EntityType.project,
          metadata: const {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
        ),
      },
      relations: const {},
      followUps: const [],
    );

    final next = merge(
      state,
      'Maya works on Atlas.',
      const GraphPatch(
        entities: [],
        relations: [
          RelationPatch(source: 'Maya', target: 'Atlas', label: 'works_on'),
        ],
        supersedes: [],
      ),
    ).next;

    expect(next.entities['maya']?.mentions, 2);
    expect(next.entities['atlas']?.mentions, 2);
  });
}

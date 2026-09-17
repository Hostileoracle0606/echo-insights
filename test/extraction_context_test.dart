import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/extraction_context.dart';

void main() {
  final now = DateTime.utc(2026, 9, 17);

  Entity entity(String id, String name, {String? description}) => Entity(
        id: id,
        name: name,
        type: EntityType.person,
        description: description,
        metadata: const {},
        mentions: 1,
        firstSeen: now,
        lastSeen: now,
      );

  JournalState stateOf(
    List<Entity> entities, {
    List<Relation> relations = const [],
  }) =>
      JournalState(
        entries: const [],
        entities: {for (final item in entities) item.id: item},
        relations: {for (final item in relations) item.id: item},
        followUps: const [],
      );

  test('ranks exact names before semantic retrieval results', () {
    final context = compileExtractionContext(
      transcript: 'Sarah called about ceramics.',
      state: stateOf([
        entity('pottery', 'Pottery'),
        entity('sarah', 'Sarah'),
      ]),
      retrievedEntityIds: const ['pottery', 'sarah'],
      recentTurns: const [],
    );

    expect(context.entities.map((item) => item.id), ['sarah', 'pottery']);
  });

  test('keeps retrieved older entities and their active relation ids', () {
    final context = compileExtractionContext(
      transcript: 'She started repairing bowls again.',
      state: stateOf(
        [entity('maya', 'Maya'), entity('kintsugi', 'Kintsugi')],
        relations: [
          Relation(
            id: 'r-practices',
            source: 'maya',
            target: 'kintsugi',
            label: 'practices',
            metadata: const {},
            createdAt: now,
          ),
        ],
      ),
      retrievedEntityIds: const ['maya', 'kintsugi'],
      recentTurns: const [],
    );

    expect(context.entities.map((item) => item.id), ['maya', 'kintsugi']);
    expect(context.relations.single.id, 'r-practices');
    expect(
      buildExtractionUserMessage('She started repairing bowls again.', context),
      contains('[r-practices] Maya --practices--> Kintsugi'),
    );
  });

  test('packs the most recent turns under one prompt budget', () {
    final turns = List.generate(
      8,
      (index) => (role: 'user', text: 'conversation turn $index'),
    );
    final context = compileExtractionContext(
      transcript: 'A sufficiently long finalized utterance.',
      state: JournalState.empty(),
      retrievedEntityIds: const [],
      recentTurns: turns,
      budget: 140,
    );

    expect(context.tokensUsed, lessThanOrEqualTo(context.budget));
    expect(context.recentConversation.last.text, 'conversation turn 7');
    expect(context.recentConversation.map((turn) => turn.text),
        isNot(contains('conversation turn 0')));
  });
}

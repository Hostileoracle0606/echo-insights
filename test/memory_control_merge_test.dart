// LM-29: what the user removed or rewrote stays that way on the device too.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/merge.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_state.dart';

final _seen = DateTime.utc(2026, 10, 20);

Entity _maya({String? description, String source = 'extracted'}) => Entity(
      id: 'maya',
      name: 'Maya',
      type: EntityType.person,
      description: description,
      descriptionSource: source,
      metadata: const {},
      mentions: 1,
      firstSeen: _seen,
      lastSeen: _seen,
    );

const _priyaAndMaya = GraphPatch(
  entities: [
    EntityPatch(name: 'Priya', type: EntityType.person),
    EntityPatch(name: 'Maya', type: EntityType.person),
  ],
  relations: [
    RelationPatch(source: 'Priya', target: 'Maya', label: 'friend_of'),
    RelationPatch(source: 'Maya', target: 'Priya', label: 'calls'),
  ],
  supersedes: [],
);

void main() {
  group('Entity.descriptionSource', () {
    test('defaults to extracted, so existing constructors still work', () {
      expect(_maya().descriptionSource, 'extracted');
    });

    test('is read from and written to descriptionSource', () {
      final json = _maya(description: 'x', source: 'user').toJson();
      expect(json['descriptionSource'], 'user');
      expect(Entity.fromJson(json).descriptionSource, 'user');
    });

    test('is extracted when the JSON has none', () {
      final json = _maya().toJson()..remove('descriptionSource');
      expect(Entity.fromJson(json).descriptionSource, 'extracted');
    });
  });

  group('merge with suppressed ids', () {
    test('skips the suppressed entity and every relation touching it', () {
      final result = merge(
        JournalState.empty(),
        'Priya and Maya talked.',
        _priyaAndMaya,
        suppressed: const {'priya'},
      );

      expect(result.next.entities.keys, ['maya']);
      expect(result.next.relations, isEmpty);
      expect(result.change.entities.map((e) => e.id), ['maya']);
      expect(result.change.relations, isEmpty);
      expect(result.change.entryEntityIds, ['maya']);
      expect(result.change.entryRelationIds, isEmpty);
      expect(result.next.entries.single.entityIds, ['maya']);
    });

    test('an empty patch (Lumen\'s own turn) commits a bare entry', () {
      final prev = JournalState.empty()
          .copyWith(entities: {'maya': _maya(description: 'A friend.')});

      final result = merge(prev, 'How did that go?', GraphPatch.empty(),
          suppressed: const {'priya'});

      expect(result.next.entities.keys, ['maya']);
      expect(result.change.entities, isEmpty);
      expect(result.change.relations, isEmpty);
      expect(result.change.entryEntityIds, isEmpty);
      expect(result.next.entries.single.text, 'How did that go?');
    });

    test('changes nothing when nothing is suppressed', () {
      final result =
          merge(JournalState.empty(), 'Priya and Maya talked.', _priyaAndMaya);

      expect(result.next.entities.keys, containsAll(['priya', 'maya']));
      expect(result.next.relations, hasLength(2));
    });
  });

  group('merge with a user-written description', () {
    test('never replaces it with an extracted one', () {
      final prev = JournalState.empty().copyWith(entities: {
        'maya': _maya(description: 'My closest friend.', source: 'user'),
      });

      final result = merge(
        prev,
        'Maya again.',
        const GraphPatch(
          entities: [
            EntityPatch(
              name: 'Maya',
              type: EntityType.person,
              description: 'An extractor rewrite.',
            ),
          ],
          relations: [],
          supersedes: [],
        ),
      );

      final maya = result.next.entities['maya']!;
      expect(maya.description, 'My closest friend.');
      expect(maya.descriptionSource, 'user');
      expect(maya.mentions, 2);
      expect(result.change.entities.single.description, 'My closest friend.');
    });

    test('still replaces an extracted one', () {
      final prev = JournalState.empty()
          .copyWith(entities: {'maya': _maya(description: 'Old.')});

      final result = merge(
        prev,
        'Maya again.',
        const GraphPatch(
          entities: [
            EntityPatch(
                name: 'Maya', type: EntityType.person, description: 'New.'),
          ],
          relations: [],
          supersedes: [],
        ),
      );

      expect(result.next.entities['maya']!.description, 'New.');
      expect(result.next.entities['maya']!.descriptionSource, 'extracted');
    });
  });
}

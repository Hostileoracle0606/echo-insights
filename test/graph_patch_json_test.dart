import 'package:flutter_test/flutter_test.dart';

import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';

void main() {
  test('a GraphPatch survives a JSON round trip intact', () {
    // This is what makes a durable extraction checkpoint possible: the stored
    // result must reconstruct exactly, or a restart would reuse something
    // different from what the model actually returned.
    const patch = GraphPatch(
      entities: [
        EntityPatch(
          name: 'Acme',
          type: EntityType.organization,
          description: 'Where the user works.',
          metadata: {'industry': 'software'},
          questions: ['What does Acme build?'],
        ),
      ],
      relations: [
        RelationPatch(
          source: 'Sarah',
          target: 'Acme',
          label: 'works_at',
          metadata: {'since': '2024'},
        ),
      ],
      supersedes: ['rel-old'],
    );

    final restored = GraphPatch.fromJson(patch.toJson());

    expect(restored.entities.single.name, 'Acme');
    expect(restored.entities.single.type, EntityType.organization);
    expect(restored.entities.single.description, 'Where the user works.');
    expect(restored.entities.single.metadata, {'industry': 'software'});
    expect(restored.entities.single.questions, ['What does Acme build?']);
    expect(restored.relations.single.source, 'Sarah');
    expect(restored.relations.single.target, 'Acme');
    expect(restored.relations.single.label, 'works_at');
    expect(restored.relations.single.metadata, {'since': '2024'});
    expect(restored.supersedes, ['rel-old']);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/noise_filter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';

void main() {
  test('filters default noise entities and relations touching them', () {
    const patch = GraphPatch(
      entities: [
        EntityPatch(name: 'I', type: EntityType.person),
        EntityPatch(name: 'Maya', type: EntityType.person),
        EntityPatch(name: 'today', type: EntityType.event),
        EntityPatch(name: 'Brooklyn', type: EntityType.place),
      ],
      relations: [
        RelationPatch(source: 'I', target: 'Maya', label: 'knows'),
        RelationPatch(source: 'Maya', target: 'Brooklyn', label: 'lives_in'),
      ],
      supersedes: [],
    );

    final filtered = filterNoise(patch);

    expect(filtered.entities.map((entity) => entity.name), [
      'Maya',
      'Brooklyn',
    ]);
    expect(filtered.relations, hasLength(1));
    expect(filtered.relations.single.source, 'Maya');
    expect(filtered.relations.single.target, 'Brooklyn');
  });

  test('extra noise words are filtered', () {
    const patch = GraphPatch(
      entities: [
        EntityPatch(name: 'Lumen', type: EntityType.other),
        EntityPatch(name: 'Maya', type: EntityType.person),
      ],
      relations: [],
      supersedes: [],
    );

    final filtered = filterNoise(patch, extra: {'lumen'});

    expect(filtered.entities.map((entity) => entity.name), ['Maya']);
  });
}

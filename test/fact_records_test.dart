import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/fact_records.dart';
import 'package:lumen/logic/noise_filter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';

// EC-03: what extraction found becomes the rows record_memory_facts decides
// on (repeat, supersede, pinned). Entity names map to the same slugs merge()
// gives them, and a removed or forgotten entity gets no facts.

const _fact = FactPatch(
  entity: 'Savings Goal',
  attribute: 'amount',
  valueNum: 8000,
  unit: 'USD',
  status: 'confirmed',
  previousValueNum: 5000,
);

void main() {
  test('facts round-trip through the durable checkpoint', () {
    const patch = GraphPatch(
      entities: [EntityPatch(name: 'Savings Goal', type: EntityType.concept)],
      relations: [],
      supersedes: [],
      facts: [
        _fact,
        FactPatch(
          entity: 'Priya',
          attribute: 'moving_to',
          valueText: 'Lisbon',
          status: 'proposed',
          eventAt: '2026-12-01T12:00:00Z',
        ),
      ],
    );
    final back = GraphPatch.fromJson(patch.toJson());
    expect(back.facts.map((f) => f.toJson()), patch.facts.map((f) => f.toJson()));
  });

  test('a patch without facts keeps its old checkpoint shape', () {
    expect(GraphPatch.empty().toJson().containsKey('facts'), isFalse);
    expect(GraphPatch.fromJson({'entities': [], 'relations': []}).facts, isEmpty);
  });

  test('malformed facts in a checkpoint are dropped, not fatal', () {
    final patch = GraphPatch.fromJson({
      'entities': [],
      'relations': [],
      'facts': [
        {'entity': 'Priya', 'attribute': 'age', 'status': 'confirmed'},
        {'entity': 'Priya', 'attribute': 'age', 'valueNum': 'x', 'status': 'confirmed'},
        'nonsense',
        _fact.toJson(),
      ],
    });
    expect(patch.facts.map((f) => f.entity), ['Savings Goal']);
  });

  test('facts are keyed by the slug merge gives the entity', () {
    final rows = factRecords(const GraphPatch(
      entities: [],
      relations: [],
      supersedes: [],
      facts: [_fact],
    ));
    expect(rows, [
      {
        'entityId': 'savings-goal',
        'attribute': 'amount',
        'valueNum': 8000,
        'unit': 'USD',
        'status': 'confirmed',
        'previousValueNum': 5000,
      },
    ]);
  });

  test('a removed or forgotten entity gets no facts', () {
    final rows = factRecords(
      const GraphPatch(entities: [], relations: [], supersedes: [], facts: [_fact]),
      suppressed: {'savings-goal'},
    );
    expect(rows, isEmpty);
  });

  test('spokenAt carries the local offset, so "yesterday" is the user\'s day', () {
    expect(isoWithOffset(DateTime.utc(2026, 11, 22, 22, 23)), '2026-11-22T22:23:00+00:00');
    final local = DateTime(2026, 11, 22, 17, 23);
    final iso = isoWithOffset(local);
    expect(iso, startsWith('2026-11-22T17:23:00'));
    expect(RegExp(r'[+-]\d\d:\d\d$').hasMatch(iso), isTrue);
    expect(DateTime.parse(iso).isAtSameMomentAs(local), isTrue);
  });

  test('the noise filter keeps facts, except on entities it drops', () {
    final filtered = filterNoise(
      const GraphPatch(
        entities: [
          EntityPatch(name: 'savings goal', type: EntityType.concept),
          EntityPatch(name: 'Lumen', type: EntityType.other),
        ],
        relations: [],
        supersedes: [],
        facts: [
          _fact,
          FactPatch(entity: 'Lumen', attribute: 'release', valueText: 'December', status: 'proposed'),
        ],
      ),
      extra: {'lumen'},
    );
    expect(filtered.facts.map((f) => f.entity), ['Savings Goal']);
  });
}

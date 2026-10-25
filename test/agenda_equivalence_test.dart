// The faster buildAgenda must say the same things as the original.
//
// Fields without ties must match exactly. Ranked lists must hold the same
// scores in the same order; which of several equal-scoring items fills the
// last slot may differ, because the original used Dart's unstable List.sort
// and the new code breaks ties by first appearance.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/agenda.dart';
import 'package:lumen/models/journal_state.dart';

import 'perf/latency_bench_test.dart' show syntheticState;
import 'support/legacy_agenda.dart';

int _sharedNeighbours(JournalState s, String aName, String bName) {
  String idOf(String name) =>
      s.entities.values.firstWhere((e) => e.name == name).id;
  final a = idOf(aName), b = idOf(bName);
  final neighbours = <String, Set<String>>{};
  for (final r in s.relations.values.where((r) => r.isActive)) {
    neighbours.putIfAbsent(r.source, () => {}).add(r.target);
    neighbours.putIfAbsent(r.target, () => {}).add(r.source);
  }
  return neighbours[a]!.intersection(neighbours[b]!).length;
}

void main() {
  final random = Random(2026);
  final cases = [
    for (final n in [5, 20, 60, 150]) (n, 11),
    for (var i = 0; i < 25; i++) (8 + random.nextInt(120), random.nextInt(1 << 30)),
  ];
  for (final (n, seed) in cases) {
    test('same agenda, n=$n seed=$seed', () {
      final state = syntheticState(n, seed: seed);
      const probe = 'Entity 3 told entity 12 about ENTITY 4 and Entity 40';
      final now = buildAgenda(state, lastUserText: probe);
      final before = legacyBuildAgenda(state, lastUserText: probe);

      expect(now.justMentioned, before.justMentioned);
      expect(now.openQuestions.map((q) => '${q.entity}:${q.question}'),
          before.openQuestions.map((q) => '${q.entity}:${q.question}'));
      expect(now.entityCount, before.entityCount);
      expect(now.relationCount, before.relationCount);

      int mentionsOf(String name) =>
          state.entities.values.firstWhere((e) => e.name == name).mentions;
      expect(now.thinEntities.map(mentionsOf), before.thinEntities.map(mentionsOf));

      expect(now.uncertainRelations.map((r) => r.score),
          before.uncertainRelations.map((r) => r.score));

      expect(
        now.bridgeCandidates.map((p) => _sharedNeighbours(state, p.$1, p.$2)),
        before.bridgeCandidates.map((p) => _sharedNeighbours(state, p.$1, p.$2)),
      );
    });
  }

  test('ties are deterministic: the same state gives the same agenda', () {
    final state = syntheticState(300, seed: 5);
    final a = buildAgenda(state, lastUserText: 'Entity 7');
    final b = buildAgenda(state, lastUserText: 'Entity 7');
    expect(a.bridgeCandidates, b.bridgeCandidates);
    expect(a.thinEntities, b.thinEntities);
  });
}

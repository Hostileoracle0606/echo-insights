import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/agenda.dart';
import 'package:lumen/logic/graph_summary.dart';

import 'perf/latency_bench_test.dart' show syntheticState;

void main() {
  for (final (n, seed) in [(10, 1), (80, 2), (300, 3)]) {
    test('relation counts and coverage match the per-entity scan, n=$n', () {
      final state = syntheticState(n, seed: seed);
      final body = graphSummaryBody(state, lastUserText: 'Entity 2');
      final thin = buildAgenda(state, lastUserText: 'Entity 2').thinEntities;
      final rows = body['entities'] as List<Map<String, dynamic>>;
      final entities = state.entities.values.toList();
      expect(rows.length, entities.length);
      for (var i = 0; i < entities.length; i++) {
        final entity = entities[i];
        final scanned = state.relations.values
            .where((r) =>
                r.isActive && (r.source == entity.id || r.target == entity.id))
            .length;
        expect(rows[i]['name'], entity.name);
        expect(rows[i]['relationCount'], scanned, reason: entity.id);
        expect(rows[i]['coverage'],
            thin.contains(entity.name) ? 'thin' : 'developing');
      }
    });
  }
}

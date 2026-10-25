import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/noise_filter.dart';
import 'package:lumen/services/extraction_context.dart';

import 'perf/latency_bench_test.dart' show syntheticState;

void main() {
  test('named entities are found exactly as the per-entity contains did', () {
    final random = Random(3);
    for (var round = 0; round < 40; round++) {
      final state = syntheticState(5 + random.nextInt(200), seed: random.nextInt(1 << 30));
      final transcript = 'Today entity ${random.nextInt(50)} met Entity '
          '${random.nextInt(300)}, and ENTITY ${random.nextInt(9)}!';
      final retrieved = [for (var i = 0; i < 5; i++) 'e${random.nextInt(60)}'];

      // The original candidate order: exact names first, then retrieved ids.
      final normalized = normalizeName(transcript);
      final exact = [
        for (final e in state.entities.values)
          if (normalizeName(e.name).length >= 2 &&
              normalized.contains(normalizeName(e.name)))
            e.id,
      ];
      final expected = <String>[];
      for (final id in [...exact, ...retrieved.where((id) => !exact.contains(id))]) {
        if (expected.length >= 20) break;
        if (state.entities[id] == null || expected.contains(id)) continue;
        expected.add(id);
      }

      final context = compileExtractionContext(
        transcript: transcript,
        state: state,
        retrievedEntityIds: retrieved,
        recentTurns: const [],
        budget: 1 << 30,
      );
      expect(context.entities.map((e) => e.id).toList(), expected);
    }
  });
}

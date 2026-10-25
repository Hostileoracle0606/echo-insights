// Per-tick cost of the graph layout: the all-pairs original (test/support/)
// against the Barnes–Hut charge, on the same bodies.
//
// Run: flutter test test/perf/graph_layout_bench_test.dart --reporter expanded
//
// "fresh" is every body just spawned in a pile at the centre, as the latency
// bench times it; "settled" is the cooled layout, reheated, which is what
// the Memory screen (LM-27) steps when a node is added. Results print as
// `PERF` lines; docs/performance-fixes.md quotes them.
@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/graph_layout.dart';

import '../support/graph_layout_fixture.dart';
import '../support/legacy_graph_layout.dart';
import 'latency_bench_test.dart' show bench;

void report(String name, int n, double before, double after) {
  // ignore: avoid_print
  print('PERF layout $name n=$n before=${before.toStringAsFixed(2)}ms '
      'after=${after.toStringAsFixed(2)}ms '
      'speedup≈${(before / after).toStringAsFixed(1)}x');
}

/// Puts [legacy]'s bodies where [layout]'s are, at rest.
void _copyBodies(GraphLayout layout, LegacyGraphLayout legacy) {
  for (final e in layout.nodes.entries) {
    legacy.nodes[e.key] =
        LayoutNode(position: e.value.position, radius: e.value.radius);
  }
  for (final n in layout.nodes.values) {
    n.velocity = Offset.zero;
  }
}

void main() {
  for (final n in [300, 2000]) {
    final runs = n <= 300 ? 31 : 15;

    test('fresh layout step, n=$n', () {
      final graph = SyntheticGraph(n);
      final legacy = graph.legacyLayout();
      final layout = graph.layout();
      final before = bench('layout_fresh_legacy', n, () {
        legacy.reheat();
        legacy.step();
      }, runs: runs);
      final after = bench('layout_fresh_barnes_hut', n, () {
        layout.reheat();
        layout.step();
      }, runs: runs);
      report('fresh', n, before, after);
      expect(after, lessThan(before));
    });

    test('settled layout step, n=$n', () {
      final graph = SyntheticGraph(n);
      final layout = graph.layout();
      settle(() => layout.isMoving, layout.step);
      final legacy = graph.legacyLayout();
      _copyBodies(layout, legacy);
      final before = bench('layout_settled_legacy', n, () {
        legacy.reheat();
        legacy.step();
      }, runs: runs);
      final after = bench('layout_settled_barnes_hut', n, () {
        layout.reheat();
        layout.step();
      }, runs: runs);
      report('settled', n, before, after);
      expect(after, lessThan(before));
    });
  }
}

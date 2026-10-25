// Barnes–Hut charge vs the all-pairs original (test/support/): the settled
// layouts may differ body by body, but must look the same — as few overlaps,
// the same footprint — and the per-tick charge must stay close.
//
// The 2,000-body case takes about half a minute (the all-pairs reference is
// the slow part), so it is tagged perf.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/graph_layout.dart';

import 'support/graph_layout_fixture.dart';
import 'support/legacy_graph_layout.dart';

void _compareSettled(int n) {
  final graph = SyntheticGraph(n);
  final legacy = graph.legacyLayout();
  final layout = graph.layout();
  final legacyTicks = settle(() => legacy.isMoving, legacy.step);
  final ticks = settle(() => layout.isMoving, layout.step);

  final legacyOverlaps = overlaps(legacy.nodes.values);
  final newOverlaps = overlaps(layout.nodes.values);
  final legacyBox = extent(legacy.nodes.values);
  final newBox = extent(layout.nodes.values);
  // ignore: avoid_print
  print('QUALITY n=$n ticks=$legacyTicks/$ticks '
      'overlaps=$legacyOverlaps/$newOverlaps '
      'box=${legacyBox.width.round()}x${legacyBox.height.round()}/'
      '${newBox.width.round()}x${newBox.height.round()}');

  expect(ticks, legacyTicks, reason: 'alpha cooling is unchanged');
  // Settling is chaotic: across spawn seeds the all-pairs layout itself ends
  // with 46–66 overlaps at 2,000 bodies (Barnes–Hut: 45–70), so the bound
  // is that spread, not an exact count. Footprints agree within 1.5%.
  expect(newOverlaps, lessThanOrEqualTo(max(10, (legacyOverlaps * 1.5).ceil())));
  expect(newBox.width / legacyBox.width, closeTo(1, 0.05));
  expect(newBox.height / legacyBox.height, closeTo(1, 0.05));
}

/// The charge each body felt on one tick from the same state, recovered from
/// its velocity (starting at rest, no links: v = (charge + gravity)·0.6).
List<Offset> _chargeFelt(
    Map<String, LayoutNode> start, Map<String, LayoutNode> after,
    {required double alpha, required Offset center}) {
  return [
    for (final id in start.keys)
      after[id]!.velocity / (1 - GraphLayout.velocityDecay) -
          (center - start[id]!.position) * (GraphLayout.gravity * alpha),
  ];
}

void main() {
  test('settled 300-body graph matches the all-pairs layout', () {
    _compareSettled(300);
  });

  test('settled 2,000-body graph matches the all-pairs layout', () {
    _compareSettled(2000);
  }, tags: ['perf'], timeout: const Timeout(Duration(minutes: 3)));

  test('one tick of Barnes–Hut charge stays within a few percent', () {
    // A settled 600-body graph spans several cutoffs, so the tree both
    // approximates and skips cells.
    final graph = SyntheticGraph(600);
    final settled = graph.legacyLayout();
    settle(() => settled.isMoving, settled.step);
    final start = {
      for (final e in settled.nodes.entries)
        e.key: LayoutNode(position: e.value.position, radius: e.value.radius),
    };
    void seed(Map<String, LayoutNode> nodes) {
      for (final e in start.entries) {
        nodes[e.key] =
            LayoutNode(position: e.value.position, radius: e.value.radius);
      }
    }

    final legacy = LegacyGraphLayout()..size = phone;
    final layout = GraphLayout()..size = phone;
    seed(legacy.nodes);
    seed(layout.nodes);
    legacy.step();
    layout.step();
    expect(layout.alpha, legacy.alpha);

    final exact = _chargeFelt(start, legacy.nodes,
        alpha: legacy.alpha, center: legacy.visibleCenter);
    final approx = _chargeFelt(start, layout.nodes,
        alpha: layout.alpha, center: layout.visibleCenter);
    // Relative to the typical charge, not each body's own: a settled body's
    // net charge is a near-cancellation, so its own magnitude can be ~0.
    final typical =
        exact.fold(0.0, (sum, f) => sum + f.distance) / exact.length;
    final errors = [
      for (var i = 0; i < exact.length; i++)
        (approx[i] - exact[i]).distance / typical,
    ]..sort();
    final median = errors[errors.length ~/ 2];
    final p95 = errors[(errors.length * 0.95).floor()];
    // ignore: avoid_print
    print('QUALITY charge error median=${(median * 100).toStringAsFixed(2)}% '
        'p95=${(p95 * 100).toStringAsFixed(2)}% '
        'max=${(errors.last * 100).toStringAsFixed(2)}%');
    expect(median, lessThan(0.03));
    expect(p95, lessThan(0.08));
  });

  test('graphs up to the limit keep the exact all-pairs charge', () {
    final graph = SyntheticGraph(GraphLayout.exactChargeLimit);
    final legacy = graph.legacyLayout();
    final layout = graph.layout();
    for (var i = 0; i < 120; i++) {
      legacy.step();
      layout.step();
    }
    for (final id in legacy.nodes.keys) {
      expect(layout.nodes[id]!.position, legacy.nodes[id]!.position);
    }
  });
}

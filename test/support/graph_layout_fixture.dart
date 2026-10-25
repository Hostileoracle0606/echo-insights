// Shared inputs and measures for comparing GraphLayout with the all-pairs
// LegacyGraphLayout: test/graph_layout_quality_test.dart and
// test/perf/graph_layout_bench_test.dart.
import 'dart:math';
import 'dart:ui';

import 'package:lumen/logic/graph_layout.dart';

import 'legacy_graph_layout.dart';

const phone = Size(390, 700);

/// A journal-like graph: [n] bodies with radii 6–14 and about 1.5n links.
class SyntheticGraph {
  SyntheticGraph(this.n, {int seed = 7}) {
    final random = Random(seed);
    radii = [for (var i = 0; i < n; i++) 6 + random.nextDouble() * 8];
    links = [
      for (var i = 0; i < (n * 1.5).round(); i++)
        () {
          final s = random.nextInt(n);
          var t = random.nextInt(n);
          if (t == s) t = (t + 1) % n;
          return ('n$s', 'n$t');
        }(),
    ];
  }

  final int n;
  late final List<double> radii;
  late final List<(String, String)> links;

  /// Spawns every body at the visible centre, as the app does for nodes
  /// with no placed neighbour, with the same seed for both layouts.
  GraphLayout layout() {
    final layout = GraphLayout(random: Random(1))..size = phone;
    for (var i = 0; i < n; i++) {
      layout.spawn('n$i', radius: radii[i]);
    }
    return layout..links = links;
  }

  LegacyGraphLayout legacyLayout() {
    final layout = LegacyGraphLayout(random: Random(1))..size = phone;
    for (var i = 0; i < n; i++) {
      layout.spawn('n$i', radius: radii[i]);
    }
    return layout..links = links;
  }
}

/// Steps until cooled (about 300 ticks from alpha 1). Returns the tick count.
int settle(bool Function() isMoving, void Function() step) {
  var ticks = 0;
  for (; ticks < 2000 && isMoving(); ticks++) {
    step();
  }
  return ticks;
}

/// Pairs of discs that overlap (centres closer than the two radii).
int overlaps(Iterable<LayoutNode> nodes) {
  final list = nodes.toList();
  var count = 0;
  for (var i = 0; i < list.length; i++) {
    for (var j = i + 1; j < list.length; j++) {
      final p = list[i], q = list[j];
      if ((p.position - q.position).distance < p.radius + q.radius) count++;
    }
  }
  return count;
}

/// The bodies' bounding box, discs included.
Size extent(Iterable<LayoutNode> nodes) {
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final n in nodes) {
    left = min(left, n.position.dx - n.radius);
    right = max(right, n.position.dx + n.radius);
    top = min(top, n.position.dy - n.radius);
    bottom = max(bottom, n.position.dy + n.radius);
  }
  return Size(right - left, bottom - top);
}

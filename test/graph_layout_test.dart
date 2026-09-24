// Graph gravity: the layout must gather toward the visible centre (between
// the top bar and the dock) and cool to rest — never drift to the edges.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/graph_layout.dart';

GraphLayout _phone() => GraphLayout()..size = const Size(390, 700);

void _settle(GraphLayout layout, {int maxTicks = 2000}) {
  for (var i = 0; i < maxTicks && layout.isMoving; i++) {
    layout.step();
  }
}

void main() {
  test('two unlinked nodes settle near the visible centre', () {
    final layout = _phone();
    // Worst case for the old physics: both born far from the centre.
    layout.spawn('a', radius: 10, near: const Offset(30, 90));
    layout.spawn('b', radius: 10, near: const Offset(360, 560));
    _settle(layout);

    expect(layout.isMoving, isFalse, reason: 'alpha cooling must stop it');
    final center = layout.visibleCenter;
    for (final node in layout.nodes.values) {
      expect((node.position - center).distance, lessThan(80));
    }
  });

  test('disconnected components all gather around the centre', () {
    final layout = _phone();
    for (final id in ['a1', 'a2', 'a3', 'b1', 'b2', 'c1']) {
      layout.spawn(id, radius: 12);
    }
    layout.links = const [('a1', 'a2'), ('a2', 'a3'), ('b1', 'b2')];
    _settle(layout);

    final center = layout.visibleCenter;
    var mean = Offset.zero;
    for (final node in layout.nodes.values) {
      mean += node.position;
    }
    mean /= layout.nodes.length.toDouble();
    expect((mean - center).distance, lessThan(20));
    for (final node in layout.nodes.values) {
      expect((node.position - center).distance, lessThan(160));
    }
  });

  test('camera fit frames every node inside the visible area', () {
    final layout = _phone();
    for (var i = 0; i < 14; i++) {
      layout.spawn('n$i', radius: 14);
    }
    _settle(layout);
    for (var i = 0; i < 400 && layout.fitCamera(); i++) {}

    expect(layout.cameraSettled, isTrue);
    for (final node in layout.nodes.values) {
      final screen = node.position * layout.scale + layout.pan;
      expect(screen.dx, inInclusiveRange(0, 390));
      expect(screen.dy,
          inInclusiveRange(GraphLayout.topInset, 700 - GraphLayout.bottomInset));
    }
  });

  test('a new node is born beside its neighbour and reheats the layout', () {
    final layout = _phone();
    layout.spawn('a', radius: 10);
    _settle(layout);
    expect(layout.isMoving, isFalse);

    final anchor = layout.nodes['a']!.position;
    final b = layout.spawn('b', radius: 10, near: anchor);
    expect((b.position - anchor).distance, lessThan(18));
    expect(layout.isMoving, isTrue);
  });
}

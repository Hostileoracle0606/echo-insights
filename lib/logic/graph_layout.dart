import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

/// One simulated body. [radius] is the drawn disc radius; collide and camera
/// fit both read it.
class LayoutNode {
  Offset position;
  Offset velocity = Offset.zero;
  double radius;

  LayoutNode({required this.position, required this.radius});
}

/// Force-directed layout for the journal graph, with d3-force semantics
/// ported from the web's graph-view.tsx (charge -260, link 70, collide 22,
/// forceX/forceY(0).strength(0.06), alpha cooling, zoomToFit). Charge and
/// link distance are scaled for a phone canvas.
///
/// Gravity must beat charge at short range or nodes march to the walls. Two
/// unlinked nodes at ±r from the centre feel a push of 150/(2r) and a pull of
/// 0.06·r, so they rest at r ≈ 35px. The previous Fruchterman–Reingold
/// constants balanced near r ≈ 990px on a phone, which is why nodes piled up
/// against the old clamp at the screen edges.
///
/// Pure Dart (no widgets) so the physics can be stepped in unit tests.
class GraphLayout {
  static const charge = -150.0;
  static const chargeMaxDistance = 320.0;
  static const linkDistance = 62.0;
  static const collidePad = 10.0;
  static const gravity = 0.06;
  static const velocityDecay = 0.4;
  static const alphaDecay = 0.0228; // d3 default: 1 - 0.001^(1/300)
  static const alphaMin = 0.001;
  static const reheatAlpha = 0.8;

  /// Up to this many bodies, charge runs the exact all-pairs loop. Above it,
  /// a Barnes–Hut quadtree with opening angle [theta] (d3-force's default,
  /// as on the web) approximates distant clusters by their centre of mass.
  static const exactChargeLimit = 64;
  static const theta = 0.9;

  /// Chrome the graph must stay clear of: top bar above, voice dock below.
  static const topInset = 68.0;
  static const bottomInset = 120.0;

  GraphLayout({Random? random}) : _random = random ?? Random(13);

  final Random _random;
  final Map<String, LayoutNode> nodes = {};
  List<(String, String)> links = const [];
  Size size = Size.zero;

  double alpha = 1;
  Offset pan = Offset.zero;
  double scale = 1;
  bool cameraSettled = false;

  bool get isMoving => alpha >= alphaMin;

  /// Centre of the area visible between the top bar and the dock — the point
  /// gravity pulls toward and the camera frames on.
  Offset get visibleCenter => Offset(
        size.width / 2,
        (topInset + max(topInset, size.height - bottomInset)) / 2,
      );

  /// d3ReheatSimulation equivalent; also re-arms the camera fit.
  void reheat([double to = reheatAlpha]) {
    alpha = max(alpha, to);
    cameraSettled = false;
  }

  /// Spawns beside [near] (a linked neighbour) or the visible centre, never
  /// at a random point on the canvas.
  LayoutNode spawn(String id, {required double radius, Offset? near}) {
    reheat();
    final base = near ?? visibleCenter;
    return nodes[id] = LayoutNode(
      position: base +
          Offset(_random.nextDouble() * 24 - 12, _random.nextDouble() * 24 - 12),
      radius: radius,
    );
  }

  /// One simulation tick. No-op once the layout has cooled.
  void step() {
    if (!isMoving) return;
    alpha += (0 - alpha) * alphaDecay;
    final a = alpha;
    final bodies = nodes.values.toList(growable: false);
    if (bodies.isEmpty) return;

    // Links (d3.forceLink): pull toward linkDistance, strength 1/min(degree),
    // split by the endpoints' degree ratio.
    final pairs = <(LayoutNode, LayoutNode)>[];
    final degree = <LayoutNode, int>{};
    for (final (sourceId, targetId) in links) {
      final s = nodes[sourceId];
      final t = nodes[targetId];
      if (s == null || t == null || identical(s, t)) continue;
      pairs.add((s, t));
      degree[s] = (degree[s] ?? 0) + 1;
      degree[t] = (degree[t] ?? 0) + 1;
    }
    for (final (s, t) in pairs) {
      var delta = (t.position + t.velocity) - (s.position + s.velocity);
      if (delta == Offset.zero) delta = _jiggle();
      final length = delta.distance;
      final ds = degree[s]!, dt = degree[t]!;
      final step = delta * ((length - linkDistance) / length * a / min(ds, dt));
      final bias = ds / (ds + dt);
      t.velocity -= step * bias;
      s.velocity += step * (1 - bias);
    }

    // Charge (d3.forceManyBody): v += d · strength·α / d².
    if (bodies.length <= exactChargeLimit) {
      const maxD2 = chargeMaxDistance * chargeMaxDistance;
      for (final n in bodies) {
        for (final other in bodies) {
          if (identical(n, other)) continue;
          var delta = other.position - n.position;
          var d2 = delta.distanceSquared;
          if (d2 >= maxD2) continue;
          if (d2 < 1) {
            delta = _jiggle();
            d2 = 1;
          }
          n.velocity += delta * (charge * a / d2);
        }
      }
    } else {
      _ChargeTree(bodies).apply(bodies, charge * a, _random);
    }

    // Gravity well (d3.forceX/forceY) toward the visible centre.
    final center = visibleCenter;
    for (final n in bodies) {
      n.velocity += (center - n.position) * (gravity * a);
    }

    // Integrate. No clamp: the camera frames the graph instead.
    for (final n in bodies) {
      n.velocity *= 1 - velocityDecay;
      n.position += n.velocity;
    }

    // Collide: separate overlapping discs (radius + label breathing room).
    for (var i = 0; i < bodies.length; i++) {
      for (var j = i + 1; j < bodies.length; j++) {
        final p = bodies[i], q = bodies[j];
        final reach = p.radius + q.radius + 2 * collidePad;
        var delta = q.position - p.position;
        var distance = delta.distance;
        if (distance >= reach) continue;
        if (distance == 0) {
          delta = _jiggle();
          distance = delta.distance;
        }
        final push = delta * ((reach - distance) / distance * 0.35);
        p.position -= push;
        q.position += push;
      }
    }
  }

  /// Eases [pan]/[scale] toward the graph's bounding box (the web's
  /// zoomToFit). Returns whether the camera moved.
  bool fitCamera() {
    if (nodes.isEmpty || cameraSettled || size == Size.zero) return false;
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (final n in nodes.values) {
      // Horizontal slack for the centred label; the label sits below the disc.
      left = min(left, n.position.dx - n.radius - 40);
      right = max(right, n.position.dx + n.radius + 40);
      top = min(top, n.position.dy - n.radius - 8);
      bottom = max(bottom, n.position.dy + n.radius + 22);
    }
    final visibleH = max(1.0, size.height - bottomInset - topInset);
    final targetScale = min(
      (size.width - 28) / (right - left),
      (visibleH - 16) / (bottom - top),
    ).clamp(0.55, 1.3).toDouble();
    final targetPan = visibleCenter -
        Offset((left + right) / 2, (top + bottom) / 2) * targetScale;

    final nextScale = scale + (targetScale - scale) * 0.08;
    final nextPan = pan + (targetPan - pan) * 0.08;
    final arrived = (nextScale - targetScale).abs() < 0.001 &&
        (nextPan - targetPan).distance < 0.3;
    scale = arrived ? targetScale : nextScale;
    pan = arrived ? targetPan : nextPan;
    // Only stop following once the layout itself is at rest.
    if (arrived && !isMoving) cameraSettled = true;
    return true;
  }

  Offset _jiggle() => Offset(
        (_random.nextDouble() - 0.5) * 1e-3,
        (_random.nextDouble() - 0.5) * 1e-3,
      );
}

/// Barnes–Hut quadtree for one charge pass, rebuilt each tick from the
/// bodies' positions (which the pass doesn't move).
///
/// Every cell owns a contiguous run of [_order]. A cell is skipped when its
/// bodies' bounding box lies wholly beyond [GraphLayout.chargeMaxDistance],
/// and stands in for its bodies (total charge at their centre of mass) only
/// when the box lies wholly inside it and d3's opening test passes. Cells
/// that straddle the cutoff are opened, so no body pushes from beyond it.
/// Opened leaves apply each body exactly, with the all-pairs jiggle rule.
class _ChargeTree {
  static const _leafSize = 8;
  static const _maxDepth = 24;

  _ChargeTree(List<LayoutNode> bodies)
      : _xs = Float64List(bodies.length),
        _ys = Float64List(bodies.length),
        _order = Int32List(bodies.length),
        _scratch = Int32List(bodies.length) {
    for (var i = 0; i < bodies.length; i++) {
      final p = bodies[i].position;
      _xs[i] = p.dx;
      _ys[i] = p.dy;
      _order[i] = i;
    }
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (var i = 0; i < bodies.length; i++) {
      minX = min(minX, _xs[i]);
      maxX = max(maxX, _xs[i]);
      minY = min(minY, _ys[i]);
      maxY = max(maxY, _ys[i]);
    }
    final width = max(max(maxX - minX, maxY - minY), 1.0);
    _reserve(1);
    _build(0, minX, minY, width, 0, bodies.length, 0);
  }

  final Float64List _xs, _ys;
  final Int32List _order, _scratch;

  // Per cell: quadrant width, bounding box and centre of its bodies, the
  // body run [_start, _start + _count), and its children (_kidCount of them
  // from _firstKid; none for a leaf).
  int _cells = 0;
  Float64List _width = Float64List(0);
  Float64List _minX = Float64List(0), _minY = Float64List(0);
  Float64List _maxX = Float64List(0), _maxY = Float64List(0);
  Float64List _cx = Float64List(0), _cy = Float64List(0);
  Int32List _start = Int32List(0), _count = Int32List(0);
  Int32List _firstKid = Int32List(0), _kidCount = Int32List(0);

  /// Adds `velocity += d · strength / d²` from every body within the cutoff
  /// (approximated for far cells) to each of [bodies].
  void apply(List<LayoutNode> bodies, double strength, Random random) {
    const maxD2 = GraphLayout.chargeMaxDistance * GraphLayout.chargeMaxDistance;
    const theta2 = GraphLayout.theta * GraphLayout.theta;
    final stack = Int32List(3 * _maxDepth + 8);
    for (var i = 0; i < bodies.length; i++) {
      final px = _xs[i], py = _ys[i];
      var vx = 0.0, vy = 0.0;
      var top = 0;
      stack[top++] = 0;
      while (top > 0) {
        final c = stack[--top];
        final x0 = _minX[c], x1 = _maxX[c], y0 = _minY[c], y1 = _maxY[c];
        final nx = px < x0 ? x0 - px : (px > x1 ? px - x1 : 0.0);
        final ny = py < y0 ? y0 - py : (py > y1 ? py - y1 : 0.0);
        final near2 = nx * nx + ny * ny;
        if (near2 >= maxD2) continue;
        if (near2 > 0) {
          var dx = _cx[c] - px, dy = _cy[c] - py;
          var l = dx * dx + dy * dy;
          final w = _width[c];
          final fx = max(px - x0, x1 - px), fy = max(py - y0, y1 - py);
          if (w * w < theta2 * l && fx * fx + fy * fy < maxD2) {
            if (l < 1) {
              dx = (random.nextDouble() - 0.5) * 1e-3;
              dy = (random.nextDouble() - 0.5) * 1e-3;
              l = 1;
            }
            final k = strength * _count[c] / l;
            vx += dx * k;
            vy += dy * k;
            continue;
          }
        }
        final kids = _kidCount[c];
        if (kids > 0) {
          final first = _firstKid[c];
          for (var k = 0; k < kids; k++) {
            stack[top++] = first + k;
          }
          continue;
        }
        final end = _start[c] + _count[c];
        for (var s = _start[c]; s < end; s++) {
          final j = _order[s];
          if (j == i) continue;
          var dx = _xs[j] - px, dy = _ys[j] - py;
          var d2 = dx * dx + dy * dy;
          if (d2 >= maxD2) continue;
          if (d2 < 1) {
            dx = (random.nextDouble() - 0.5) * 1e-3;
            dy = (random.nextDouble() - 0.5) * 1e-3;
            d2 = 1;
          }
          final k = strength / d2;
          vx += dx * k;
          vy += dy * k;
        }
      }
      bodies[i].velocity += Offset(vx, vy);
    }
  }

  /// Fills cell [c] (quadrant at [x0],[y0], side [width]) from the run of
  /// [count] bodies at [start], splitting it into quadrants while it holds
  /// more than [_leafSize] bodies that aren't all coincident.
  void _build(
      int c, double x0, double y0, double width, int start, int count, int depth) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    var sumX = 0.0, sumY = 0.0;
    final end = start + count;
    for (var s = start; s < end; s++) {
      final x = _xs[_order[s]], y = _ys[_order[s]];
      sumX += x;
      sumY += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    _width[c] = width;
    _minX[c] = minX;
    _maxX[c] = maxX;
    _minY[c] = minY;
    _maxY[c] = maxY;
    _cx[c] = sumX / count;
    _cy[c] = sumY / count;
    _start[c] = start;
    _count[c] = count;
    _kidCount[c] = 0;
    if (count <= _leafSize ||
        depth >= _maxDepth ||
        (minX == maxX && minY == maxY)) {
      return;
    }

    // Counting sort of the run into quadrants 0..3 (bit 0: right, bit 1:
    // below), through the scratch buffer.
    final half = width / 2, mx = x0 + half, my = y0 + half;
    final sizes = [0, 0, 0, 0];
    for (var s = start; s < end; s++) {
      final b = _order[s];
      sizes[(_xs[b] >= mx ? 1 : 0) | (_ys[b] >= my ? 2 : 0)]++;
    }
    final offsets = [start, 0, 0, 0];
    for (var q = 1; q < 4; q++) {
      offsets[q] = offsets[q - 1] + sizes[q - 1];
    }
    final cursor = [...offsets];
    for (var s = start; s < end; s++) {
      final b = _order[s];
      _scratch[cursor[(_xs[b] >= mx ? 1 : 0) | (_ys[b] >= my ? 2 : 0)]++] = b;
    }
    _order.setRange(start, end, _scratch, start);

    var kids = 0;
    for (var q = 0; q < 4; q++) {
      if (sizes[q] > 0) kids++;
    }
    final first = _cells;
    _reserve(kids);
    _firstKid[c] = first;
    _kidCount[c] = kids;
    var k = first;
    for (var q = 0; q < 4; q++) {
      if (sizes[q] == 0) continue;
      _build(k++, (q & 1) == 0 ? x0 : mx, (q & 2) == 0 ? y0 : my, half,
          offsets[q], sizes[q], depth + 1);
    }
  }

  /// Claims [n] consecutive cells, growing the arrays as needed.
  void _reserve(int n) {
    final need = _cells + n;
    if (need > _width.length) {
      final capacity = max(need, max(16, _width.length * 2));
      Float64List f(Float64List old) => Float64List(capacity)..setAll(0, old);
      Int32List i(Int32List old) => Int32List(capacity)..setAll(0, old);
      _width = f(_width);
      _minX = f(_minX);
      _minY = f(_minY);
      _maxX = f(_maxX);
      _maxY = f(_maxY);
      _cx = f(_cx);
      _cy = f(_cy);
      _start = i(_start);
      _count = i(_count);
      _firstKid = i(_firstKid);
      _kidCount = i(_kidCount);
    }
    _cells = need;
  }
}

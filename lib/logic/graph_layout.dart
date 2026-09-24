import 'dart:math';
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

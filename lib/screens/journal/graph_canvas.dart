import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../logic/graph_layout.dart';
import '../../models/entity.dart';
import '../../models/journal_state.dart';
import '../../models/relation.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../widgets/node_glyph.dart';
import 'entity_note_sheet.dart';

class GraphCanvas extends StatefulWidget {
  final JournalState state;

  const GraphCanvas({super.key, required this.state});

  @override
  State<GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<GraphCanvas>
    with SingleTickerProviderStateMixin {
  // After a pan/pinch the camera belongs to the user for a while.
  static const _fitPause = Duration(seconds: 4);

  final _layout = GraphLayout();
  final _nodes = <String, _GraphNode>{};
  late final Ticker _ticker;
  double _scaleStart = 1;
  int _relationSignature = 0;
  DateTime? _lastGestureAt;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didUpdateWidget(covariant GraphCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Iterable<Relation> get _activeRelations =>
      widget.state.relations.values.where((relation) => relation.isActive);

  /// An already-placed node this entity is related to, so a new node is born
  /// beside its neighbour instead of at a random point on the canvas.
  Offset? _placedNeighbourOf(String id) {
    for (final relation in _activeRelations) {
      final other = relation.source == id
          ? relation.target
          : relation.target == id
              ? relation.source
              : null;
      final node = other == null ? null : _nodes[other];
      if (node != null) return node.position;
    }
    return null;
  }

  void _syncNodes() {
    if (_layout.size == Size.zero) return;
    final ids = widget.state.entities.keys.toSet();
    final before = _nodes.length;
    _nodes.removeWhere((id, _) => !ids.contains(id));
    _layout.nodes.removeWhere((id, _) => !ids.contains(id));
    if (_nodes.length != before) _layout.reheat(0.3);
    for (final entity in widget.state.entities.values) {
      final node = _nodes.putIfAbsent(
        entity.id,
        () => _GraphNode(
          entity: entity,
          body: _layout.spawn(
            entity.id,
            radius: _radiusFor(entity),
            near: _placedNeighbourOf(entity.id),
          ),
          bornAt: DateTime.now(),
        ),
      );
      node.entity = entity;
      node.body.radius = _radiusFor(entity);
    }
    // New or retired links change the equilibrium; wake the layout for them.
    final signature = Object.hashAllUnordered(
      _activeRelations.map((relation) => relation.id),
    );
    if (signature != _relationSignature) {
      _relationSignature = signature;
      _layout
        ..links = [
          for (final relation in _activeRelations)
            (relation.source, relation.target),
        ]
        ..reheat(0.5);
    }
  }

  static double _radiusFor(Entity entity) =>
      8.0 + min(12, entity.mentions * 1.8);

  bool get _fading => _nodes.values.any(
        (node) => DateTime.now().difference(node.bornAt).inMilliseconds < 320,
      );

  void _tick(Duration _) {
    if (!mounted || _layout.size == Size.zero) return;
    _syncNodes();
    final moving = _layout.isMoving;
    _layout.step();
    final gesture = _lastGestureAt;
    final userOwnsCamera =
        gesture != null && DateTime.now().difference(gesture) < _fitPause;
    final cameraMoved = !userOwnsCamera && _layout.fitCamera();
    // Once the layout has cooled and the camera has arrived, stop repainting
    // at 60fps — the web's cooldownTicks equivalent.
    if (moving || cameraMoved || _fading) setState(() {});
  }

  void _handleTap(TapUpDetails details) {
    final point = (details.localPosition - _layout.pan) / _layout.scale;
    _GraphNode? hit;
    for (final node in _nodes.values) {
      if ((node.position - point).distance <= 24) {
        hit = node;
        break;
      }
    }
    if (hit == null) return;
    showEntityNoteSheet(context, hit.entity.id);
  }

  @override
  Widget build(BuildContext context) {
    // CustomPainter can't read InheritedWidgets, so the tokens are read here
    // and handed to the painter.
    final colors = context.lumenColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layout.size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncNodes();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _handleTap,
          onScaleStart: (_) => _scaleStart = _layout.scale,
          onScaleUpdate: (details) {
            setState(() {
              _layout
                ..pan += details.focalPointDelta
                ..scale = (_scaleStart * details.scale).clamp(0.55, 2.6)
                // The user owns the camera now; auto-fit resumes only when
                // new content reheats the layout, and never within _fitPause.
                ..cameraSettled = true;
              _lastGestureAt = DateTime.now();
            });
          },
          child: CustomPaint(
            painter: _GraphPainter(
              nodes: _nodes,
              relations: widget.state.relations,
              pan: _layout.pan,
              scale: _layout.scale,
              paper: colors.paper,
              ink: colors.ink,
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _GraphPainter extends CustomPainter {
  final Map<String, _GraphNode> nodes;
  final Map<String, Relation> relations;
  final Offset pan;
  final double scale;
  final Color paper;
  final Color ink;

  _GraphPainter({
    required this.nodes,
    required this.relations,
    required this.pan,
    required this.scale,
    required this.paper,
    required this.ink,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);

    _paintAmbient(canvas, size);

    canvas
      ..save()
      ..translate(pan.dx, pan.dy)
      ..scale(scale);

    final edgePaint = Paint()
      ..color = ink.withValues(alpha: 0.18)
      ..strokeWidth = 1 / scale;
    for (final relation
        in relations.values.where((relation) => relation.isActive)) {
      final source = nodes[relation.source];
      final target = nodes[relation.target];
      if (source == null || target == null) continue;
      canvas.drawLine(source.position, target.position, edgePaint);
    }

    for (final node in nodes.values) {
      final ageMs = DateTime.now().difference(node.bornAt).inMilliseconds;
      final opacity = min(1.0, ageMs / 300);
      final color = colorForEntityType(node.entity.type);
      final radius = node.body.radius;

      canvas.drawCircle(
        node.position,
        radius + 8,
        Paint()..color = color.withValues(alpha: 0.08 * opacity),
      );
      canvas.drawCircle(
        node.position,
        radius,
        Paint()..color = color.withValues(alpha: 0.92 * opacity),
      );
      canvas.drawCircle(
        node.position,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2 / scale
          ..color = ink.withValues(alpha: 0.12 * opacity),
      );

      final textPainter = TextPainter(
        text: TextSpan(
          text: _clampLabel(node.entity.name),
          style: TextStyle(
            fontFamily: LumenText.sansFontFamily,
            color: ink.withValues(alpha: 0.9 * opacity),
            fontSize: 10 / scale.clamp(0.9, 1.4),
            height: 1.1,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 92);
      textPainter.paint(
        canvas,
        node.position + Offset(-textPainter.width / 2, radius + 5),
      );
    }

    canvas.restore();
  }

  void _paintAmbient(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ink.withValues(alpha: 0.04);
    const gap = 42.0;
    for (var x = 0.0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  String _clampLabel(String value) =>
      value.length <= 18 ? value : '${value.substring(0, 17)}…';

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}

class _GraphNode {
  Entity entity;
  final LayoutNode body;
  final DateTime bornAt;

  _GraphNode({
    required this.entity,
    required this.body,
    required this.bornAt,
  });

  Offset get position => body.position;
}

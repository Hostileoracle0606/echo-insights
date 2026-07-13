import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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
  final _random = Random(13);
  final _nodes = <String, _GraphNode>{};
  late final Ticker _ticker;
  Size _size = Size.zero;
  Offset _pan = Offset.zero;
  double _scale = 1;
  double _scaleStart = 1;

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

  void _syncNodes() {
    if (_size == Size.zero) return;
    final ids = widget.state.entities.keys.toSet();
    _nodes.removeWhere((id, _) => !ids.contains(id));
    for (final entity in widget.state.entities.values) {
      _nodes.putIfAbsent(
        entity.id,
        () => _GraphNode(
          entity: entity,
          position: Offset(
            _size.width * (0.24 + _random.nextDouble() * 0.52),
            _size.height * (0.18 + _random.nextDouble() * 0.58),
          ),
          bornAt: DateTime.now(),
        ),
      );
      _nodes[entity.id]!.entity = entity;
    }
  }

  void _tick(Duration _) {
    if (!mounted || _size == Size.zero) return;
    _syncNodes();
    _simulate();
    setState(() {});
  }

  void _simulate() {
    final nodes = _nodes.values.toList();
    if (nodes.length < 2) return;

    final area = max(1.0, _size.width * _size.height);
    final k = sqrt(area / nodes.length) * 0.6;
    final activeRelations =
        widget.state.relations.values.where((relation) => relation.isActive);

    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i];
        final b = nodes[j];
        var delta = a.position - b.position;
        var distance = max(24.0, delta.distance);
        delta = delta / distance;
        final force = (k * k / distance) * 0.016;
        a.velocity += delta * force;
        b.velocity -= delta * force;
      }
    }

    for (final relation in activeRelations) {
      final a = _nodes[relation.source];
      final b = _nodes[relation.target];
      if (a == null || b == null) continue;
      var delta = b.position - a.position;
      var distance = max(24.0, delta.distance);
      delta = delta / distance;
      final force = (distance * distance / k) * 0.002;
      a.velocity += delta * force;
      b.velocity -= delta * force;
    }

    final center = Offset(_size.width / 2, _size.height / 2);
    for (final node in nodes) {
      node.velocity += (center - node.position) * 0.0008;
      node.velocity *= 0.85;
      node.position += node.velocity;
      node.position = Offset(
        node.position.dx.clamp(28.0, max(28.0, _size.width - 28)),
        node.position.dy.clamp(68.0, max(68.0, _size.height - 120)),
      );
    }
  }

  void _handleTap(TapUpDetails details) {
    final point = (details.localPosition - _pan) / _scale;
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
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncNodes();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _handleTap,
          onScaleStart: (_) => _scaleStart = _scale,
          onScaleUpdate: (details) {
            setState(() {
              _pan += details.focalPointDelta;
              _scale = (_scaleStart * details.scale).clamp(0.55, 2.6);
            });
          },
          child: CustomPaint(
            painter: _GraphPainter(
              nodes: _nodes,
              relations: widget.state.relations,
              pan: _pan,
              scale: _scale,
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
      final radius = 8.0 + min(12, node.entity.mentions * 1.8);

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
  Offset position;
  Offset velocity;
  final DateTime bornAt;

  _GraphNode({
    required this.entity,
    required this.position,
    required this.bornAt,
  }) : velocity = Offset.zero;
}

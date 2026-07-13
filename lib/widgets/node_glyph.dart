import 'package:flutter/material.dart';

import '../models/entity.dart';
import '../theme/lumen_colors.dart';

/// Single source of truth for entity colours: the warm token palette in
/// [LumenColors.entityColors] (the same one the entity note sheet uses). The
/// graph canvas, the legend, and the sheet all resolve through here, so the
/// neon-vs-terracotta split is gone.
Color colorForEntityType(EntityType type) =>
    LumenColors.entityColors[type] ?? LumenColors.entityColors[EntityType.other]!;

class NodeGlyph extends StatelessWidget {
  final EntityType type;
  final double size;

  const NodeGlyph({
    super.key,
    required this.type,
    this.size = 12,
  });

  @override
  Widget build(BuildContext context) {
    final color = colorForEntityType(type);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.42), blurRadius: size),
        ],
      ),
    );
  }
}

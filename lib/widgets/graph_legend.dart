import 'package:flutter/material.dart';

import '../models/entity.dart';
import '../theme/lumen_colors.dart';
import '../theme/lumen_theme.dart';
import 'node_glyph.dart';

/// Collapsible entity-type legend (paper theme). Rethemed onto the tokens; the
/// glyph swatches pick up the warm palette automatically via [NodeGlyph].
class GraphLegend extends StatefulWidget {
  const GraphLegend({super.key});

  @override
  State<GraphLegend> createState() => _GraphLegendState();
}

class _GraphLegendState extends State<GraphLegend> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
        boxShadow: surface.shadowPaper,
      ),
      child: _expanded
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Collapse legend',
                      color: colors.mutedForeground,
                      onPressed: () => setState(() => _expanded = false),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ),
                  for (final type in EntityType.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NodeGlyph(type: type, size: 10),
                          const SizedBox(width: 8),
                          Text(
                            type.name,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: colors.ink),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          : IconButton(
              tooltip: 'Expand legend',
              color: colors.mutedForeground,
              onPressed: () => setState(() => _expanded = true),
              icon: const Icon(Icons.category_outlined, size: 20),
            ),
    );
  }
}

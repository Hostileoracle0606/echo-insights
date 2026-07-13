import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';

/// The journal screen's floating top bar (paper theme): a left "‹ Your
/// notebooks" back button ([onHomeTap] returns to the dashboard) and a right
/// stats pill that opens the graph sidepane via a hamburger ([onMenuTap]) and
/// shows the entity · relation counts. The split-screen toggle lives in the
/// dock, not here. The Lumen brand now lives on the dashboard.
class JournalTopBar extends StatelessWidget {
  final int entityCount;
  final int relationCount;
  final VoidCallback? onMenuTap;
  final VoidCallback? onHomeTap;

  const JournalTopBar({
    super.key,
    required this.entityCount,
    required this.relationCount,
    this.onMenuTap,
    this.onHomeTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHomeTap,
            child: Row(
              children: [
                Icon(Icons.chevron_left, size: 24, color: colors.ink),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    'Your notebooks',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.headlineMedium?.copyWith(fontSize: 19),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(11, 9, 16, 9),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
            boxShadow: surface.shadowPaper,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuButton(onTap: onMenuTap, colors: colors),
              const SizedBox(width: 8),
              Container(width: 1, height: 18, color: colors.border),
              const SizedBox(width: 10),
              Icon(Icons.bubble_chart_outlined,
                  size: 17, color: colors.mutedForeground),
              const SizedBox(width: 7),
              Text(
                '$entityCount',
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colors.ink,
                ),
              ),
              Text(
                ' · $relationCount',
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 13,
                  color: colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The hamburger that opens the graph sidepane. A compact glyph with a padded,
/// thumb-friendly hit box.
class _MenuButton extends StatelessWidget {
  final VoidCallback? onTap;
  final LumenColors colors;

  const _MenuButton({required this.onTap, required this.colors});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(Icons.menu, size: 20, color: colors.ink),
      ),
    );
  }
}

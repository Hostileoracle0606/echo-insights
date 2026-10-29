import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';

/// Shown when Lumen couldn't join a new notebook in time.
class LumenJoinFailedBanner extends StatelessWidget {
  const LumenJoinFailedBanner({
    super.key,
    required this.onRetry,
    required this.onOpenWithoutVoice,
  });

  final VoidCallback onRetry;
  final VoidCallback onOpenWithoutVoice;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: colors.card,
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Lumen couldn't join",
              style: textTheme.titleSmall?.copyWith(color: colors.ink),
            ),
            const SizedBox(height: 4),
            Text(
              'Check your connection and try again, or open the notebook '
              'and start talking later.',
              style: textTheme.bodySmall
                  ?.copyWith(color: colors.mutedForeground),
            ),
            // Wraps the buttons onto two lines when a narrow phone (or a
            // large text size) can't fit them side by side.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              children: [
                TextButton(
                  onPressed: onOpenWithoutVoice,
                  child: const Text('Open without voice'),
                ),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: colors.amber),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

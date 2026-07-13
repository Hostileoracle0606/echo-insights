import 'package:flutter/material.dart';
import 'package:lumen/theme/lumen_colors.dart';

/// An entity reference rendered like an in-app Obsidian `[[wikilink]]`.
///
/// Tappable links use ink text with an amber underline. A null [onTap] is used
/// for self-links and renders as plain text so it does not look interactive.
class WikiLink extends StatelessWidget {
  final String entityId;
  final String label;
  final VoidCallback? onTap;

  const WikiLink({
    super.key,
    required this.entityId,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.4,
          color: colors.ink,
        );

    if (onTap == null) {
      return Text(
        label,
        style: baseStyle?.copyWith(decoration: TextDecoration.none),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Text(
        label,
        style: baseStyle?.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: colors.amber,
          decorationThickness: 1.5,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';
import '../theme/lumen_theme.dart';
import 'eyebrow.dart';

/// The flat muted surface shared by [ContextTile] and [ContextList]: context,
/// not a result, so no border and no shadow.
class _FlatTile extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _FlatTile({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).extension<LumenSurface>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: context.lumenColors.muted,
        borderRadius: BorderRadius.circular(surface.radiusTile),
      ),
      child: child,
    );
  }
}

/// A flat context tile ("ASK", "SINCE LAST TIME"): optional leading icon, an
/// eyebrow and a short body.
class ContextTile extends StatelessWidget {
  final IconData? icon;

  /// Defaults to ink.
  final Color? iconColor;
  final String eyebrow;
  final String body;

  static const surfaceKey = ValueKey('context-tile-surface');

  const ContextTile({
    super.key,
    this.icon,
    this.iconColor,
    required this.eyebrow,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return _FlatTile(
      key: surfaceKey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: iconColor ?? colors.ink),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Eyebrow(eyebrow),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontFamily: LumenText.sansFontFamily,
                    fontSize: 14,
                    height: 1.45,
                    color: colors.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One entry in a [ContextList].
class ContextItem {
  final String title;

  /// Muted 12pt sub-note on the same line as the title.
  final String? note;

  /// Dot colour; defaults to [LumenColors.upsertRing] (you adding to memory).
  /// Pass a token from `context.lumenColors`, never a literal.
  final Color? dotColor;

  /// Hollow dot for open items (a question still to ask).
  final bool open;

  /// VoiceOver label for the remove button; defaults to "Remove <title>".
  final String? removeLabel;

  /// False for an item the list's onRemove doesn't apply to (an open item
  /// next to things Lumen remembers): no × button, same row height.
  final bool removable;

  const ContextItem({
    required this.title,
    this.note,
    this.dotColor,
    this.open = false,
    this.removeLabel,
    this.removable = true,
  });
}

/// The flat tile holding a list — the "LUMEN WILL REMEMBER" pattern from the
/// Close screen. With [onRemove], each item gets a labelled 44pt × button.
class ContextList extends StatelessWidget {
  final String eyebrow;
  final List<ContextItem> items;
  final ValueChanged<ContextItem>? onRemove;

  const ContextList({
    super.key,
    required this.eyebrow,
    required this.items,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return _FlatTile(
      // The remove buttons' 44pt boxes carry their own inset on the right.
      padding: EdgeInsets.fromLTRB(14, 12, onRemove == null ? 14 : 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(eyebrow),
          const SizedBox(height: 6),
          for (final item in items) _ItemRow(item: item, onRemove: onRemove),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final ContextItem item;
  final ValueChanged<ContextItem>? onRemove;

  const _ItemRow({required this.item, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final dot = item.dotColor ?? colors.upsertRing;
    return ConstrainedBox(
      // Rows match the remove button's height so lists with and without it
      // keep the same rhythm.
      constraints: BoxConstraints(minHeight: onRemove == null ? 32 : 44),
      child: Row(
        children: [
          Container(
            key:
                ValueKey(item.open ? 'context-dot-open' : 'context-dot-filled'),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: item.open ? null : dot,
              border: item.open ? Border.all(color: dot, width: 1.5) : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: item.title,
                children: [
                  if (item.note != null)
                    TextSpan(
                      text: '  ${item.note}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
                ],
              ),
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 14,
                height: 1.4,
                color: colors.ink,
              ),
            ),
          ),
          if (onRemove != null && item.removable)
            Semantics(
              button: true,
              label: item.removeLabel ?? 'Remove ${item.title}',
              excludeSemantics: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onRemove!(item),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: colors.mutedForeground,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

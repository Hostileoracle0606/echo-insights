import 'package:flutter/material.dart';

import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';

/// Header for the conversation-mode screens: a back control that carries the
/// mode's title, and a [trailing] slot (LM-11 puts the timer pill and End
/// there). The title ellipsizes before the trailing slot gives up any width.
/// Just talk keeps its own JournalTopBar.
class ModeHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const ModeHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(10, 18, 16, 0),
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                button: true,
                label: 'Back, $title',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBack,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_left, size: 24, color: colors.ink),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: LumenText.display(
                              size: 19,
                              color: colors.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

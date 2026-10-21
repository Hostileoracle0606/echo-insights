import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';

/// The journal screen's floating top bar (paper theme): a left "‹" back
/// button ([onHomeTap] returns to the dashboard; VoiceOver reads "Your
/// notebooks"), the session controls — mute Lumen ([onMuteTap]) and End
/// ([onEndTap]) — and a right stats pill that opens the graph sidepane via a hamburger ([onMenuTap]) and
/// shows the entity · relation counts. The view toggle lives in the pill, not
/// here. The Lumen brand now lives on the dashboard.
///
/// Mute and End moved here from the dock (LM-10). Where mute finally lives is
/// still open, so the pair is one self-contained [_SessionControls] widget.
/// The back button is icon-only so all four fit a 375pt screen untruncated;
/// with its "Your notebooks" label the bar needs ~400pt.
class JournalTopBar extends StatelessWidget {
  final int entityCount;
  final int relationCount;
  final VoidCallback? onMenuTap;
  final VoidCallback? onHomeTap;

  /// Lumen's voice is muted; the icon shows the state.
  final bool muted;
  final VoidCallback? onMuteTap;

  /// Ends the live session; null (drawn dimmed and inert) when there is none.
  final VoidCallback? onEndTap;

  const JournalTopBar({
    super.key,
    required this.entityCount,
    required this.relationCount,
    this.onMenuTap,
    this.onHomeTap,
    this.muted = false,
    this.onMuteTap,
    this.onEndTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;

    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Your notebooks',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHomeTap,
            child: SizedBox(
              width: 44,
              height: 44,
              // Glyph on the gutter line, as the labelled button had it.
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(Icons.chevron_left, size: 28, color: colors.ink),
              ),
            ),
          ),
        ),
        const Spacer(),
        _SessionControls(
          muted: muted,
          onMuteTap: onMuteTap,
          onEndTap: onEndTap,
          colors: colors,
        ),
        const SizedBox(width: 8),
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

/// Mute Lumen and End, each with a 44pt hit box. End is dimmed and inert
/// without a session.
class _SessionControls extends StatelessWidget {
  final bool muted;
  final VoidCallback? onMuteTap;
  final VoidCallback? onEndTap;
  final LumenColors colors;

  const _SessionControls({
    required this.muted,
    required this.onMuteTap,
    required this.onEndTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final canEnd = onEndTap != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: muted ? 'Unmute Lumen' : 'Mute Lumen',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onMuteTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                muted ? Icons.volume_off : Icons.volume_up,
                size: 20,
                color: colors.ink,
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          enabled: canEnd,
          label: 'End session',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onEndTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    'End',
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: canEnd
                          ? colors.ink
                          : colors.mutedForeground.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

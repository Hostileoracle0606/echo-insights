import 'package:flutter/material.dart';

import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';
import '../theme/lumen_theme.dart';
import 'eyebrow.dart';

/// What sits in a row's 30pt circle: a check (done) or a number (order).
/// How it's drawn — ink-filled in the hero, a hollow ring in plain rows — is
/// up to [ResultCard], so the same row can be promoted to hero unchanged.
class ResultBadge {
  final int? number;

  const ResultBadge.check() : number = null;
  const ResultBadge.number(int n) : number = n;

  bool get isCheck => number == null;
}

/// One line of a [ResultCard]: a badge, an optional small label, the text and
/// an optional meta line. [onTap] makes the whole row tappable (e.g. a quote
/// that opens its conversation).
class ResultRow {
  final ResultBadge badge;
  final String? label;
  final String text;
  final String? meta;
  final VoidCallback? onTap;

  const ResultRow({
    required this.badge,
    this.label,
    required this.text,
    this.meta,
    this.onTap,
  });
}

/// The raised card every conversation ends with ("One card rule"): eyebrow
/// header with an optional go-deeper corner button, an optional ink-badged
/// hero row on [LumenColors.highlight] (the one thing first), plain rows, and
/// an optional footer note and text action.
class ResultCard extends StatelessWidget {
  final String eyebrow;
  final VoidCallback? onExpand;

  /// Required when [onExpand] is set, e.g. "Open your full review brief".
  final String? expandLabel;
  final ResultRow? hero;
  final List<ResultRow> rows;
  final String? footerNote;
  final String? footerActionLabel;
  final VoidCallback? onFooterAction;

  static const heroKey = ValueKey('result-card-hero');
  static const footerKey = ValueKey('result-card-footer');

  const ResultCard({
    super.key,
    required this.eyebrow,
    this.onExpand,
    this.expandLabel,
    this.hero,
    this.rows = const [],
    this.footerNote,
    this.footerActionLabel,
    this.onFooterAction,
  }) : assert(
          onExpand == null || expandLabel != null,
          'An icon-only corner button needs an expandLabel for VoiceOver.',
        );

  bool get _hasFooter => footerNote != null || footerActionLabel != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    final divider = Divider(height: 1, thickness: 1, color: colors.muted);

    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(surface.radius2xl),
        border: Border.all(color: colors.border),
        boxShadow: surface.shadowPaper,
      ),
      // Clip inside the 1pt border so the hero's fill keeps the rounded
      // corners.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(surface.radius2xl - 1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              eyebrow: eyebrow,
              onExpand: onExpand,
              expandLabel: expandLabel,
            ),
            divider,
            if (hero != null) _HeroRow(row: hero!),
            for (final (i, row) in rows.indexed) ...[
              // The hero's fill already separates it from the header.
              if (i > 0 || hero != null) divider,
              _PlainRow(row: row),
            ],
            if (_hasFooter) ...[
              divider,
              _Footer(
                note: footerNote,
                actionLabel: footerActionLabel,
                onAction: onFooterAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String eyebrow;
  final VoidCallback? onExpand;
  final String? expandLabel;

  const _Header({
    required this.eyebrow,
    required this.onExpand,
    required this.expandLabel,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(child: Eyebrow(eyebrow)),
            if (onExpand != null)
              Semantics(
                button: true,
                label: expandLabel,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onExpand,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.open_in_full,
                      size: 16,
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final ResultBadge badge;
  final bool filled;

  const _Badge({required this.badge, required this.filled});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final fg = filled ? colors.paper : colors.lumenLabel;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? colors.ink : null,
        border: filled ? null : Border.all(color: colors.border, width: 1.5),
      ),
      child: badge.isCheck
          ? Icon(Icons.check, size: filled ? 14 : 13, color: fg)
          : Text(
              '${badge.number}',
              style: LumenText.display(
                size: filled ? 16 : 15,
                // Numerals read as ink in the hollow ring; lumenLabel is for
                // the check, which marks Lumen's record of a done thing.
                color: filled ? colors.paper : colors.ink,
                height: 1,
              ),
            ),
    );
  }
}

/// Text column shared by hero and plain rows: label, text, meta.
class _RowBody extends StatelessWidget {
  final ResultRow row;
  final Color labelColor;
  final TextStyle textStyle;

  const _RowBody({
    required this.row,
    required this.labelColor,
    required this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (row.label != null) ...[
          Eyebrow(row.label!, color: labelColor),
          const SizedBox(height: 4),
        ],
        Text(row.text, style: textStyle),
        if (row.meta != null) ...[
          const SizedBox(height: 4),
          Text(
            row.meta!,
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 12,
              height: 1.35,
              color: colors.mutedForeground,
            ),
          ),
        ],
      ],
    );
  }
}

/// Wraps a row so it reads as one VoiceOver item, and is a button when it
/// has an onTap.
Widget _rowShell(ResultRow row, Widget child) {
  final merged = MergeSemantics(
    child: Semantics(button: row.onTap != null, child: child),
  );
  if (row.onTap == null) return merged;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: row.onTap,
    child: merged,
  );
}

class _HeroRow extends StatelessWidget {
  final ResultRow row;

  const _HeroRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return _rowShell(
      row,
      Container(
        key: ResultCard.heroKey,
        color: colors.highlight,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Badge(badge: row.badge, filled: true),
            const SizedBox(width: 14),
            Expanded(
              child: _RowBody(
                row: row,
                labelColor: colors.youLabel,
                textStyle: LumenText.display(
                  size: 19,
                  height: 1.3,
                  color: colors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  final ResultRow row;

  const _PlainRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return _rowShell(
      row,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Badge(badge: row.badge, filled: false),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                // Optically centre a one-line body on the 30pt badge.
                padding: const EdgeInsets.only(top: 4),
                child: _RowBody(
                  row: row,
                  labelColor: colors.mutedForeground,
                  textStyle: TextStyle(
                    fontFamily: LumenText.sansFontFamily,
                    fontSize: 15,
                    height: 1.4,
                    color: colors.ink,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final String? note;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Footer({
    required this.note,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Padding(
      key: ResultCard.footerKey,
      padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            Expanded(
              child: note == null
                  ? const SizedBox.shrink()
                  : Text(
                      note!,
                      style: TextStyle(
                        fontFamily: LumenText.sansFontFamily,
                        fontSize: 12,
                        color: colors.mutedForeground,
                      ),
                    ),
            ),
            if (actionLabel != null)
              Semantics(
                button: true,
                enabled: onAction != null,
                label: actionLabel,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onAction,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    child: Center(
                      widthFactor: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          actionLabel!,
                          style: TextStyle(
                            fontFamily: LumenText.sansFontFamily,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: colors.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:lumen/models/entity.dart';

/// Lumen's color tokens, ported from the web app's `styles.css` (light mode).
/// Values are exact OKLCH->sRGB conversions; the source `oklch()` is noted on
/// each line for traceability. Registered as a [ThemeExtension] so screens read
/// them via `Theme.of(context).extension<LumenColors>()` (see [LumenColorsX]).
@immutable
class LumenColors extends ThemeExtension<LumenColors> {
  final Color paper;
  final Color ink;
  final Color amber;
  final Color amberSoft;
  final Color sage;
  final Color card;
  final Color secondary;
  final Color border;
  final Color input;
  final Color muted;
  final Color mutedForeground;
  final Color destructive;
  final Color destructiveForeground;

  // Result-card tokens (LM-09), from the Conversation Modes prototype. The
  // label tokens exist because sage (4.31:1) and amber (2.39:1) are too faint
  // for small text on paper; those two stay for dots, rings and fills.
  final Color highlight;
  final Color sageSoft;
  final Color sageInk;
  final Color lumenLabel;
  final Color youLabel;
  final Color lumenBody;

  const LumenColors({
    required this.paper,
    required this.ink,
    required this.amber,
    required this.amberSoft,
    required this.sage,
    required this.card,
    required this.secondary,
    required this.border,
    required this.input,
    required this.muted,
    required this.mutedForeground,
    required this.destructive,
    required this.destructiveForeground,
    required this.highlight,
    required this.sageSoft,
    required this.sageInk,
    required this.lumenLabel,
    required this.youLabel,
    required this.lumenBody,
  });

  static const light = LumenColors(
    paper: Color(0xFFF9F5EC), // oklch(0.97 0.012 85)
    ink: Color(0xFF17100C), // oklch(0.18 0.015 50)
    amber: Color(0xFFEB881F), // oklch(0.72 0.16 60)
    amberSoft: Color(0xFFF2D1AD), // oklch(0.88 0.06 70)
    sage: Color(0xFF527D65), // oklch(0.55 0.06 160)
    card: Color(0xFFFEFBF6), // oklch(0.99 0.008 85)
    secondary: Color(0xFFEAE4DA), // oklch(0.92 0.015 80)
    border: Color(0xFFD5CCC1), // oklch(0.85 0.018 75)
    input: Color(0xFFDDD7CD), // oklch(0.88 0.015 80)
    muted: Color(0xFFECE7DF), // oklch(0.93 0.012 80)
    mutedForeground: Color(0xFF564B42), // oklch(0.42 0.02 60)
    destructive: Color(0xFFCC272E), // oklch(0.55 0.2 25)
    destructiveForeground: Color(0xFFF8F8F8), // oklch(0.98 0 0)
    // "One thing first" row behind a result card's hero. Ink on it: 16.85:1.
    highlight: Color(0xFFFBF1E4),
    // Done-chip background. sageInk on it: 7.35:1.
    sageSoft: Color(0xFFDCE7DF),
    // Text on sageSoft.
    sageInk: Color(0xFF2F4D3D),
    // Small "Lumen" labels and in-text checks. 6.05:1 on paper.
    lumenLabel: Color(0xFF3F6550),
    // Small "You" labels and the hero row's label. 6.13:1 on highlight,
    // 6.30:1 on paper.
    youLabel: Color(0xFF8A4A0C),
    // Lumen's serif lines in transcripts. 12.62:1 on paper.
    lumenBody: Color(0xFF3A2A1E),
  );

  /// Ring/dot colour for Lumen reading memory (recall).
  Color get recallRing => sage;

  /// Ring/dot colour for you adding to memory (upsert).
  Color get upsertRing => amber;

  /// Knowledge-graph node palette, ported 1:1 from the web's
  /// `graph-view.tsx` TYPE_COLORS (plain hex there too, since canvas can't
  /// read CSS vars). Static -- not part of copyWith/lerp.
  static const Map<EntityType, Color> entityColors = {
    EntityType.person: Color(0xFFC97B3A),
    EntityType.place: Color(0xFF5B8A72),
    EntityType.organization: Color(0xFF7A6DC4),
    EntityType.project: Color(0xFFC0A040),
    EntityType.event: Color(0xFFCF6A52),
    EntityType.activity: Color(0xFF4AA39E),
    EntityType.concept: Color(0xFF4A7AB8),
    EntityType.emotion: Color(0xFFB85A8A),
    EntityType.other: Color(0xFF8A8A8A),
  };

  @override
  LumenColors copyWith({
    Color? paper,
    Color? ink,
    Color? amber,
    Color? amberSoft,
    Color? sage,
    Color? card,
    Color? secondary,
    Color? border,
    Color? input,
    Color? muted,
    Color? mutedForeground,
    Color? destructive,
    Color? destructiveForeground,
    Color? highlight,
    Color? sageSoft,
    Color? sageInk,
    Color? lumenLabel,
    Color? youLabel,
    Color? lumenBody,
  }) {
    return LumenColors(
      paper: paper ?? this.paper,
      ink: ink ?? this.ink,
      amber: amber ?? this.amber,
      amberSoft: amberSoft ?? this.amberSoft,
      sage: sage ?? this.sage,
      card: card ?? this.card,
      secondary: secondary ?? this.secondary,
      border: border ?? this.border,
      input: input ?? this.input,
      muted: muted ?? this.muted,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      destructive: destructive ?? this.destructive,
      destructiveForeground:
          destructiveForeground ?? this.destructiveForeground,
      highlight: highlight ?? this.highlight,
      sageSoft: sageSoft ?? this.sageSoft,
      sageInk: sageInk ?? this.sageInk,
      lumenLabel: lumenLabel ?? this.lumenLabel,
      youLabel: youLabel ?? this.youLabel,
      lumenBody: lumenBody ?? this.lumenBody,
    );
  }

  @override
  LumenColors lerp(ThemeExtension<LumenColors>? other, double t) {
    if (other is! LumenColors) return this;
    return LumenColors(
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      amberSoft: Color.lerp(amberSoft, other.amberSoft, t)!,
      sage: Color.lerp(sage, other.sage, t)!,
      card: Color.lerp(card, other.card, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      border: Color.lerp(border, other.border, t)!,
      input: Color.lerp(input, other.input, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      destructive: Color.lerp(destructive, other.destructive, t)!,
      destructiveForeground:
          Color.lerp(destructiveForeground, other.destructiveForeground, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
      sageSoft: Color.lerp(sageSoft, other.sageSoft, t)!,
      sageInk: Color.lerp(sageInk, other.sageInk, t)!,
      lumenLabel: Color.lerp(lumenLabel, other.lumenLabel, t)!,
      youLabel: Color.lerp(youLabel, other.youLabel, t)!,
      lumenBody: Color.lerp(lumenBody, other.lumenBody, t)!,
    );
  }
}

/// Convenience access: `context.lumenColors.amber`.
extension LumenColorsX on BuildContext {
  LumenColors get lumenColors => Theme.of(this).extension<LumenColors>()!;
}

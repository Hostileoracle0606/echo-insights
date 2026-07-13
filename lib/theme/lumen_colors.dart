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
  );

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
    );
  }
}

/// Convenience access: `context.lumenColors.amber`.
extension LumenColorsX on BuildContext {
  LumenColors get lumenColors => Theme.of(this).extension<LumenColors>()!;
}

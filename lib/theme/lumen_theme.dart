import 'package:flutter/material.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';

/// Non-color surface tokens: the radius scale and the warm, ink-tinted shadows.
@immutable
class LumenSurface extends ThemeExtension<LumenSurface> {
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;
  final double radius2xl;

  /// Flat context tiles (LM-09): between radiusXl and radius2xl.
  final double radiusTile;
  final List<BoxShadow> shadowPaper;
  final List<BoxShadow> shadowInk;

  const LumenSurface({
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
    required this.radius2xl,
    required this.radiusTile,
    required this.shadowPaper,
    required this.shadowInk,
  });

  static final light = LumenSurface(
    radiusSm: 4,
    radiusMd: 6,
    radiusLg: 8,
    radiusXl: 12,
    radius2xl: 16,
    radiusTile: 14,
    shadowPaper: [
      BoxShadow(
        color: LumenColors.light.ink.withValues(alpha: 0.06),
        blurRadius: 2,
        offset: const Offset(0, 1),
      ),
      BoxShadow(
        color: LumenColors.light.ink.withValues(alpha: 0.08),
        blurRadius: 32,
        offset: const Offset(0, 8),
      ),
    ],
    shadowInk: [
      BoxShadow(
        color: LumenColors.light.ink.withValues(alpha: 0.9),
        blurRadius: 0,
        offset: const Offset(0, 2),
      ),
    ],
  );

  @override
  LumenSurface copyWith({
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
    double? radius2xl,
    double? radiusTile,
    List<BoxShadow>? shadowPaper,
    List<BoxShadow>? shadowInk,
  }) {
    return LumenSurface(
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      radiusXl: radiusXl ?? this.radiusXl,
      radius2xl: radius2xl ?? this.radius2xl,
      radiusTile: radiusTile ?? this.radiusTile,
      shadowPaper: shadowPaper ?? this.shadowPaper,
      shadowInk: shadowInk ?? this.shadowInk,
    );
  }

  @override
  LumenSurface lerp(ThemeExtension<LumenSurface>? other, double t) {
    if (other is! LumenSurface) return this;
    return LumenSurface(
      radiusSm: radiusSm + (other.radiusSm - radiusSm) * t,
      radiusMd: radiusMd + (other.radiusMd - radiusMd) * t,
      radiusLg: radiusLg + (other.radiusLg - radiusLg) * t,
      radiusXl: radiusXl + (other.radiusXl - radiusXl) * t,
      radius2xl: radius2xl + (other.radius2xl - radius2xl) * t,
      radiusTile: radiusTile + (other.radiusTile - radiusTile) * t,
      shadowPaper:
          BoxShadow.lerpList(shadowPaper, other.shadowPaper, t) ?? shadowPaper,
      shadowInk: BoxShadow.lerpList(shadowInk, other.shadowInk, t) ?? shadowInk,
    );
  }
}

/// Assembles Lumen's light [ThemeData] without Material's default purple seed.
class LumenTheme {
  LumenTheme._();

  static ThemeData light() {
    const colors = LumenColors.light;

    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: colors.ink,
      onPrimary: colors.paper,
      primaryContainer: colors.secondary,
      onPrimaryContainer: colors.ink,
      primaryFixed: colors.secondary,
      primaryFixedDim: colors.secondary,
      onPrimaryFixed: colors.ink,
      onPrimaryFixedVariant: colors.mutedForeground,
      secondary: colors.sage,
      onSecondary: colors.paper,
      secondaryContainer: colors.muted,
      onSecondaryContainer: colors.ink,
      secondaryFixed: colors.muted,
      secondaryFixedDim: colors.muted,
      onSecondaryFixed: colors.ink,
      onSecondaryFixedVariant: colors.mutedForeground,
      tertiary: colors.amber,
      onTertiary: colors.ink,
      tertiaryContainer: colors.amberSoft,
      onTertiaryContainer: colors.ink,
      tertiaryFixed: colors.amberSoft,
      tertiaryFixedDim: colors.amberSoft,
      onTertiaryFixed: colors.ink,
      onTertiaryFixedVariant: colors.mutedForeground,
      error: colors.destructive,
      onError: colors.destructiveForeground,
      errorContainer: Color.lerp(colors.destructive, colors.paper, 0.85)!,
      onErrorContainer: colors.destructive,
      surface: colors.paper,
      onSurface: colors.ink,
      surfaceDim: colors.muted,
      surfaceBright: colors.card,
      surfaceContainerLowest: colors.paper,
      surfaceContainerLow: colors.card,
      surfaceContainer: colors.card,
      surfaceContainerHigh: colors.card,
      surfaceContainerHighest: colors.card,
      onSurfaceVariant: colors.mutedForeground,
      outline: colors.border,
      outlineVariant: Color.lerp(colors.border, colors.paper, 0.5)!,
      shadow: colors.ink,
      scrim: colors.ink,
      inverseSurface: colors.ink,
      onInverseSurface: colors.paper,
      inversePrimary: colors.amberSoft,
      surfaceTint: colors.ink,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: colors.paper,
      colorScheme: colorScheme,
      textTheme: LumenText.textTheme(
        foreground: colors.ink,
        mutedForeground: colors.mutedForeground,
      ),
      extensions: [colors, LumenSurface.light],
    );
  }
}

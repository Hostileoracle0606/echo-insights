import 'package:flutter/material.dart';

/// Lumen's typography, ported from the web app: Fraunces (display/headline +
/// titleLarge), Inter (everything else). Sizes are grounded in the actual web
/// source; the two display step-downs without a web citation are noted inline.
class LumenText {
  LumenText._();

  static const displayFontFamily = 'Fraunces';
  static const sansFontFamily = 'Inter';

  /// Centralizes Fraunces' stylistic set + variable-axis settings so the eight
  /// display/headline/title styles don't each repeat them. `opsz` tracks the
  /// point size (clamped to the axis range 9-144); WONK/SOFT pinned off for the
  /// calm editorial look; ss01 only - ss02 is absent from the Google Fonts
  /// Fraunces build, so the web app's ss02 request is already a no-op.
  static TextStyle _fraunces({
    required double size,
    required Color color,
    double? height,
    double? letterSpacing,
    double weight = 400,
  }) {
    return TextStyle(
      fontFamily: displayFontFamily,
      fontSize: size,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: [FontFeature.stylisticSet(1)],
      fontVariations: [
        FontVariation('wght', weight),
        FontVariation('opsz', size.clamp(9.0, 144.0).toDouble()),
        const FontVariation('SOFT', 0),
        const FontVariation('WONK', 0),
      ],
    );
  }

  /// Fraunces at an arbitrary size, with the same axis settings as the theme's
  /// display styles. For one-off serif sizes (card titles, badge numerals)
  /// that don't map onto a TextTheme role. Falls back to Inter for glyphs the
  /// bundled Fraunces lacks (e.g. "→" in "22 → 13 min") rather than to the
  /// system font.
  static TextStyle display({
    required double size,
    required Color color,
    double? height,
  }) =>
      _fraunces(size: size, color: color, height: height)
          .copyWith(fontFamilyFallback: const [sansFontFamily]);

  static TextTheme textTheme({
    required Color foreground,
    required Color mutedForeground,
  }) {
    return TextTheme(
      // Sidebar empty-state hero ("Voice / Journal", text-[40px] leading-[0.95]).
      displayLarge: _fraunces(
        size: 40,
        height: 0.95,
        letterSpacing: -1.0,
        color: foreground,
      ),
      // displayMedium/Small: no second hero in the web app - interpolated
      // step-down, not a citation. Confirm visually when first used.
      displayMedium: _fraunces(size: 34, height: 0.98, color: foreground),
      displaySmall: _fraunces(size: 28, height: 1.0, color: foreground),
      // Auth CardTitle ("Welcome back", text-2xl). login_screen.dart reads headlineLarge.
      headlineLarge: _fraunces(
        size: 24,
        height: 1.0,
        letterSpacing: -0.6,
        color: foreground,
      ),
      // "Lumen" wordmark lockup (text-xl).
      headlineMedium: _fraunces(size: 20, color: foreground),
      headlineSmall: _fraunces(size: 17, color: foreground),
      // Entity sidebar name heading (text-2xl) - the role graph_canvas.dart:190 calls.
      titleLarge: _fraunces(size: 24, height: 1.2, color: foreground),
      // titleMedium/Small: no web citation; Inter per "Fraunces stays special".
      titleMedium: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: foreground,
      ),
      titleSmall: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: foreground,
      ),
      bodyLarge: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 15,
        color: foreground,
      ),
      bodyMedium: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 13,
        color: foreground,
      ),
      bodySmall: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 12,
        color: mutedForeground,
      ),
      labelLarge: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: foreground,
      ),
      labelMedium: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: mutedForeground,
      ),
      labelSmall: TextStyle(
        fontFamily: sansFontFamily,
        fontSize: 11,
        color: mutedForeground,
      ),
    );
  }

  /// The "eyebrow": tiny uppercase, wide tracking - a recognizable component in
  /// the web app (section labels, "Upserting" badges). Named so call sites opt
  /// in rather than overloading labelSmall. Web evidence shows font-semibold.
  /// Tracking defaults to 0.14em (the common case); call sites needing the
  /// wider 0.22em variant use `.copyWith(letterSpacing: 2.2)`.
  static TextStyle eyebrow(Color color) {
    return TextStyle(
      fontFamily: sansFontFamily,
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.4, // ~=0.14em at 10px
      color: color,
    );
  }
}

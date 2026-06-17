# Flutter Design Tokens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Flutter theme layer (`lib/theme/lumen_colors.dart`, `lumen_text.dart`, `lumen_theme.dart`) that translates Lumen's web design tokens into Flutter constants, and wire `lib/app.dart` to it — removing the placeholder purple Material seed.

**Architecture:** Two `ThemeExtension`s — `LumenColors` (the paper/ink/amber palette + entity colors) and `LumenSurface` (radius + shadow) — registered on a `ThemeData` whose `ColorScheme` and `TextTheme` are derived from the same token values. Screens read tokens via `Theme.of(context)` / a `context.lumenColors` getter, so stock Material widgets auto-theme and a future dark variant is a drop-in. Light mode only this phase.

**Tech Stack:** Flutter 3.41.7 (Material 3), Dart token classes, bundled Inter + Fraunces *variable* fonts.

**Source of truth:** [`docs/superpowers/specs/2026-06-17-flutter-design-tokens-design.md`](../specs/2026-06-17-flutter-design-tokens-design.md) and [`docs/visual-system-audit.md`](../../visual-system-audit.md).

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/theme/lumen_colors.dart` | `LumenColors` ThemeExtension: light palette (13 color fields), `entityColors` map keyed by `EntityType`, `copyWith`/`lerp`, and a `context.lumenColors` getter. Pure data — no Flutter widget deps beyond `material.dart`. |
| `lib/theme/lumen_text.dart` | `LumenText`: a `textTheme(...)` builder covering all 15 Material text slots, a private `_fraunces(...)` helper (stylistic set + variable-axis settings), and `eyebrow(color)`. |
| `lib/theme/lumen_theme.dart` | `LumenSurface` ThemeExtension (radius scale + `shadowPaper`/`shadowInk`) and `LumenTheme.light()` assembling the final `ThemeData`. Depends on the two files above. |
| `lib/app.dart` (modify) | Replace the `ThemeData(ColorScheme.fromSeed(purple)…)` with `LumenTheme.light()`. |
| `pubspec.yaml` (modify) | Add a `fonts:` block under `flutter:` registering the two variable font files. |
| `assets/fonts/Inter.ttf`, `assets/fonts/Fraunces.ttf` | Vendored OFL variable fonts. |
| `test/theme/lumen_colors_test.dart`, `lumen_text_test.dart`, `lumen_theme_test.dart` | Unit tests per token file. |
| `test/theme/lumen_theme_smoke_test.dart` | Widget smoke test: pump `MaterialApp(theme: LumenTheme.light())`, confirm the extension resolves and no exception is thrown. |

Tasks are ordered so the pure-Dart token layer (Tasks 1–3) is built and unit-tested first with no asset dependency, then assets + app wiring land (Tasks 4–5). `LumenTheme` (Task 3) depends on `LumenColors` (Task 1) and `LumenText` (Task 2).

---

### Task 1: `LumenColors` ThemeExtension

**Files:**
- Create: `lib/theme/lumen_colors.dart`
- Test: `test/theme/lumen_colors_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/theme/lumen_colors_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/theme/lumen_colors.dart';

void main() {
  test('light palette has the exact OKLCH-derived hex values', () {
    expect(LumenColors.light.paper, const Color(0xFFF9F5EC));
    expect(LumenColors.light.ink, const Color(0xFF17100C));
    expect(LumenColors.light.amber, const Color(0xFFEB881F));
    expect(LumenColors.light.sage, const Color(0xFF527D65));
    expect(LumenColors.light.destructive, const Color(0xFFCC272E));
  });

  test('entityColors covers every EntityType', () {
    for (final type in EntityType.values) {
      expect(LumenColors.light.entityColors[type], isNotNull,
          reason: 'missing color for $type');
    }
    expect(LumenColors.light.entityColors[EntityType.person], const Color(0xFFC97B3A));
  });

  test('copyWith overrides one field and leaves the rest', () {
    final c = LumenColors.light.copyWith(amber: const Color(0xFF000000));
    expect(c.amber, const Color(0xFF000000));
    expect(c.paper, LumenColors.light.paper);
  });

  test('lerp(self, self, 0.5) returns equal values', () {
    final l = LumenColors.light.lerp(LumenColors.light, 0.5);
    expect(l.paper, LumenColors.light.paper);
    expect(l.ink, LumenColors.light.ink);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/theme/lumen_colors_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/theme/lumen_colors.dart'` (the file is not created yet).

- [ ] **Step 3: Write the implementation**

```dart
// lib/theme/lumen_colors.dart
import 'package:flutter/material.dart';
import 'package:lumen/models/entity.dart';

/// Lumen's color tokens, ported from the web app's `styles.css` (light mode).
/// Values are exact OKLCH→sRGB conversions; the source `oklch()` is noted on
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
  /// read CSS vars). Static — not part of copyWith/lerp.
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
      destructiveForeground: destructiveForeground ?? this.destructiveForeground,
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/theme/lumen_colors_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/theme/lumen_colors.dart test/theme/lumen_colors_test.dart
git commit -m "feat(theme): add LumenColors token extension"
```

---

### Task 2: `LumenText` text theme

**Files:**
- Create: `lib/theme/lumen_text.dart`
- Test: `test/theme/lumen_text_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/theme/lumen_text_test.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_text.dart';

void main() {
  final tt = LumenText.textTheme(
    foreground: const Color(0xFF17100C),
    mutedForeground: const Color(0xFF564B42),
  );

  test('all 15 text slots are defined', () {
    final slots = <TextStyle?>[
      tt.displayLarge, tt.displayMedium, tt.displaySmall,
      tt.headlineLarge, tt.headlineMedium, tt.headlineSmall,
      tt.titleLarge, tt.titleMedium, tt.titleSmall,
      tt.bodyLarge, tt.bodyMedium, tt.bodySmall,
      tt.labelLarge, tt.labelMedium, tt.labelSmall,
    ];
    expect(slots.where((s) => s == null), isEmpty);
  });

  test('display/headline/titleLarge use Fraunces; body/label use Inter', () {
    expect(tt.displayLarge!.fontFamily, 'Fraunces');
    expect(tt.headlineMedium!.fontFamily, 'Fraunces');
    expect(tt.titleLarge!.fontFamily, 'Fraunces');
    expect(tt.titleMedium!.fontFamily, 'Inter');
    expect(tt.bodyMedium!.fontFamily, 'Inter');
    expect(tt.labelSmall!.fontFamily, 'Inter');
  });

  test('Fraunces styles apply ss01 only and explicit variable axes', () {
    expect(tt.displayLarge!.fontFeatures, const [FontFeature.stylisticSet(1)]);
    final vars = tt.displayLarge!.fontVariations!;
    expect(vars, contains(const FontVariation('wght', 400)));
    expect(vars, contains(const FontVariation('opsz', 40))); // opsz tracks size
    expect(vars, contains(const FontVariation('WONK', 0)));
    expect(vars, contains(const FontVariation('SOFT', 0)));
  });

  test('eyebrow is semibold, wide-tracked, 10px', () {
    final e = LumenText.eyebrow(const Color(0xFF564B42));
    expect(e.fontFamily, 'Inter');
    expect(e.fontSize, 10);
    expect(e.fontWeight, FontWeight.w600);
    expect(e.letterSpacing, 1.4);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/theme/lumen_text_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/theme/lumen_text.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/theme/lumen_text.dart
import 'dart:ui';
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
  /// point size (clamped to the axis range 9–144); WONK/SOFT pinned off for the
  /// calm editorial look; ss01 only — ss02 is absent from the Google Fonts
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
      fontFeatures: const [FontFeature.stylisticSet(1)],
      fontVariations: [
        FontVariation('wght', weight),
        FontVariation('opsz', size.clamp(9.0, 144.0)),
        const FontVariation('SOFT', 0),
        const FontVariation('WONK', 0),
      ],
    );
  }

  static TextTheme textTheme({
    required Color foreground,
    required Color mutedForeground,
  }) {
    return TextTheme(
      // Sidebar empty-state hero ("Voice / Journal", text-[40px] leading-[0.95]).
      displayLarge: _fraunces(size: 40, height: 0.95, letterSpacing: -1.0, color: foreground),
      // displayMedium/Small: no second hero in the web app — interpolated
      // step-down, not a citation. Confirm visually when first used.
      displayMedium: _fraunces(size: 34, height: 0.98, color: foreground),
      displaySmall: _fraunces(size: 28, height: 1.0, color: foreground),
      // Auth CardTitle ("Welcome back", text-2xl). login_screen.dart reads headlineLarge.
      headlineLarge: _fraunces(size: 24, height: 1.0, letterSpacing: -0.6, color: foreground),
      // "Lumen" wordmark lockup (text-xl).
      headlineMedium: _fraunces(size: 20, color: foreground),
      headlineSmall: _fraunces(size: 17, color: foreground),
      // Entity sidebar name heading (text-2xl) — the role graph_canvas.dart:190 calls.
      titleLarge: _fraunces(size: 24, height: 1.2, color: foreground),
      // titleMedium/Small: no web citation; Inter per "Fraunces stays special".
      titleMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 16, fontWeight: FontWeight.w500, color: foreground),
      titleSmall: TextStyle(fontFamily: sansFontFamily, fontSize: 14, fontWeight: FontWeight.w500, color: foreground),
      bodyLarge: TextStyle(fontFamily: sansFontFamily, fontSize: 15, color: foreground),
      bodyMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 13, color: foreground),
      bodySmall: TextStyle(fontFamily: sansFontFamily, fontSize: 12, color: mutedForeground),
      labelLarge: TextStyle(fontFamily: sansFontFamily, fontSize: 13, fontWeight: FontWeight.w500, color: foreground),
      labelMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 12, fontWeight: FontWeight.w500, color: mutedForeground),
      labelSmall: TextStyle(fontFamily: sansFontFamily, fontSize: 11, color: mutedForeground),
    );
  }

  /// The "eyebrow": tiny uppercase, wide tracking — a recognizable component in
  /// the web app (section labels, "Upserting" badges). Named so call sites opt
  /// in rather than overloading labelSmall. Web evidence shows font-semibold.
  /// Tracking defaults to 0.14em (the common case); call sites needing the
  /// wider 0.22em variant use `.copyWith(letterSpacing: 2.2)`.
  static TextStyle eyebrow(Color color) {
    return TextStyle(
      fontFamily: sansFontFamily,
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.4, // ≈0.14em at 10px
      color: color,
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/theme/lumen_text_test.dart`
Expected: PASS (4 tests). If the analyzer flags `FontVariation`/`FontFeature` as undefined, the `import 'dart:ui';` at the top resolves them.

- [ ] **Step 5: Commit**

```bash
git add lib/theme/lumen_text.dart test/theme/lumen_text_test.dart
git commit -m "feat(theme): add LumenText typography (Fraunces/Inter variable fonts)"
```

---

### Task 3: `LumenSurface` + `LumenTheme.light()`

**Files:**
- Create: `lib/theme/lumen_theme.dart`
- Test: `test/theme/lumen_theme_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/theme/lumen_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';

void main() {
  final theme = LumenTheme.light();

  test('scaffold + key ColorScheme roles map to Lumen tokens', () {
    expect(theme.scaffoldBackgroundColor, LumenColors.light.paper);
    expect(theme.colorScheme.primary, LumenColors.light.ink);
    expect(theme.colorScheme.onPrimary, LumenColors.light.paper);
    expect(theme.colorScheme.secondary, LumenColors.light.sage);
    expect(theme.colorScheme.tertiary, LumenColors.light.amber);
    expect(theme.colorScheme.surface, LumenColors.light.paper);
    expect(theme.colorScheme.error, LumenColors.light.destructive);
    expect(theme.colorScheme.brightness, Brightness.light);
  });

  test('both extensions are registered', () {
    expect(theme.extension<LumenColors>(), LumenColors.light);
    expect(theme.extension<LumenSurface>(), isNotNull);
  });

  test('LumenSurface exposes the radius scale and warm shadows', () {
    final s = theme.extension<LumenSurface>()!;
    expect(s.radiusSm, 4);
    expect(s.radiusLg, 8);
    expect(s.radius2xl, 16);
    expect(s.shadowPaper.length, 2); // tight contact + wide ambient
    expect(s.shadowInk.length, 1); // hard letterpress edge
  });

  test('textTheme is wired with Fraunces display', () {
    expect(theme.textTheme.displayLarge!.fontFamily, 'Fraunces');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/theme/lumen_theme_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/theme/lumen_theme.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/theme/lumen_theme.dart
import 'package:flutter/material.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';

/// Non-color surface tokens: the radius scale (driven by the web's
/// `--radius: 8px`) and the two warm, ink-tinted shadow recipes. A separate
/// [ThemeExtension] from [LumenColors] so radius/shadow can be read
/// independently; colocated here since this file already wires extensions.
@immutable
class LumenSurface extends ThemeExtension<LumenSurface> {
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;
  final double radius2xl;
  final List<BoxShadow> shadowPaper;
  final List<BoxShadow> shadowInk;

  const LumenSurface({
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
    required this.radius2xl,
    required this.shadowPaper,
    required this.shadowInk,
  });

  static final light = LumenSurface(
    radiusSm: 4,
    radiusMd: 6,
    radiusLg: 8,
    radiusXl: 12,
    radius2xl: 16,
    // --shadow-paper: tight contact shadow + wide soft ambient, ink-tinted.
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
    // --shadow-ink: hard 2px offset, no blur (letterpress edge).
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
    List<BoxShadow>? shadowPaper,
    List<BoxShadow>? shadowInk,
  }) {
    return LumenSurface(
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      radiusXl: radiusXl ?? this.radiusXl,
      radius2xl: radius2xl ?? this.radius2xl,
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
      shadowPaper: BoxShadow.lerpList(shadowPaper, other.shadowPaper, t) ?? shadowPaper,
      shadowInk: BoxShadow.lerpList(shadowInk, other.shadowInk, t) ?? shadowInk,
    );
  }
}

/// Assembles Lumen's light [ThemeData]. Every Material 3 ColorScheme role is
/// set explicitly via the base `ColorScheme(...)` constructor (not
/// `ColorScheme.light(...)`/`fromSeed`) so no role keeps Material's default
/// purple. Roles without a web equivalent collapse onto the nearest real token.
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
      // Material's secondary ROLE = sage accent. The like-named
      // LumenColors.secondary (a neutral) is used for primaryContainer above
      // and stays reachable via context.lumenColors.secondary.
      secondary: colors.sage,
      onSecondary: colors.paper,
      secondaryContainer: colors.muted,
      onSecondaryContainer: colors.ink,
      secondaryFixed: colors.muted,
      secondaryFixedDim: colors.muted,
      onSecondaryFixed: colors.ink,
      onSecondaryFixedVariant: colors.mutedForeground,
      // Amber (web --accent) lands on tertiary since primary is taken by ink.
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
      // Web has two surface steps (paper/card); Material's 5-step container
      // ladder collapses onto them rather than inventing intermediate tints.
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
      // Non-const list: LumenSurface.light is `static final` (its shadow
      // colors use the runtime `withValues`), so it isn't a const expression
      // and the list literal can't be `const`.
      extensions: [colors, LumenSurface.light],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/theme/lumen_theme_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the analyzer on the whole theme layer**

Run: `flutter analyze lib/theme`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/theme/lumen_theme.dart test/theme/lumen_theme_test.dart
git commit -m "feat(theme): add LumenSurface + LumenTheme.light() assembly"
```

---

### Task 4: Vendor variable fonts + register in `pubspec.yaml`

**Files:**
- Create: `assets/fonts/Inter.ttf`, `assets/fonts/Fraunces.ttf`
- Modify: `pubspec.yaml` (add `fonts:` block under the existing `flutter:` key)

- [ ] **Step 1: Download the two OFL variable fonts**

Run:
```bash
mkdir -p "assets/fonts"
curl -L 'https://github.com/google/fonts/raw/main/ofl/inter/Inter%5Bopsz,wght%5D.ttf' -o assets/fonts/Inter.ttf
curl -L 'https://github.com/google/fonts/raw/main/ofl/fraunces/Fraunces%5BSOFT,WONK,opsz,wght%5D.ttf' -o assets/fonts/Fraunces.ttf
```

- [ ] **Step 2: Verify the files downloaded (not HTML error pages)**

Run: `ls -l assets/fonts/ && file assets/fonts/*.ttf`
Expected: `Inter.ttf` ≈ 870 KB, `Fraunces.ttf` ≈ 360 KB; `file` reports `TrueType Font data` (or `OpenType font`) for both — NOT `HTML document`. If either is a few KB or HTML, the URL failed; re-check the bracket-encoded path.

- [ ] **Step 3: Register the fonts in `pubspec.yaml`**

In `pubspec.yaml`, under the existing `flutter:` key (which already has `uses-material-design: true` and an `assets:` list), add a sibling `fonts:` block. Locate:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/.env
```

Replace with:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/.env
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter.ttf
    - family: Fraunces
      fonts:
        - asset: assets/fonts/Fraunces.ttf
```

- [ ] **Step 4: Resolve and verify the manifest**

Run: `flutter pub get && flutter analyze`
Expected: `flutter pub get` exits 0; `flutter analyze` reports `No issues found!` (a malformed `fonts:` block or missing asset surfaces as a pub error here).

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml assets/fonts/Inter.ttf assets/fonts/Fraunces.ttf
git commit -m "chore(fonts): vendor Inter + Fraunces variable fonts and register them"
```

> The web app declares `JetBrains Mono` as a rare mono family, but no Phase-2 token uses it (`LumenText` defines no mono slot), so per YAGNI it is not vendored. Add it only when a screen actually needs monospace.

---

### Task 5: Wire `lib/app.dart` + smoke test

**Files:**
- Modify: `lib/app.dart:38-45` (the `theme:` argument inside `MaterialApp.router`)
- Test: `test/theme/lumen_theme_smoke_test.dart`

- [ ] **Step 1: Write the failing smoke test**

```dart
// test/theme/lumen_theme_smoke_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';

void main() {
  testWidgets('a screen under LumenTheme resolves tokens and renders without error',
      (tester) async {
    late LumenColors readColors;
    await tester.pumpWidget(
      MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              readColors = context.lumenColors; // extension getter must resolve
              return Text('Lumen', style: Theme.of(context).textTheme.displayLarge);
            },
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(readColors, LumenColors.light);
    expect(find.text('Lumen'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `flutter test test/theme/lumen_theme_smoke_test.dart`
Expected: PASS — this test exercises only the theme layer (built in Tasks 1–3), so it passes without touching `app.dart`. It is the regression guard for the wiring in Step 3.

> Why no red phase here: `app.dart`'s `LumenApp` builds a router + Supabase-backed `authProvider` and isn't meaningfully widget-testable in isolation. This smoke test pins the *theme* contract instead; the `app.dart` swap itself is verified by `flutter analyze` (Step 4) and a manual run (Step 5).

- [ ] **Step 3: Edit `lib/app.dart`**

Add the import after the existing `package:go_router` import at the top:

```dart
import 'theme/lumen_theme.dart';
```

Then replace the `theme:` argument. Find:

```dart
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7A6FF0),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101114),
        useMaterial3: true,
      ),
```

Replace with:

```dart
      theme: LumenTheme.light(),
```

- [ ] **Step 4: Run the full test suite + analyzer**

Run: `flutter test && flutter analyze`
Expected: all tests PASS (existing `agenda`/`slugify`/`merge`/`noise_filter` tests plus the 4 new theme test files); `flutter analyze` reports `No issues found!`. If the analyzer warns that `package:flutter/material.dart`'s `Color`/`ColorScheme` import in `app.dart` is now unused, remove it — but `Color` is still used elsewhere in `app.dart`, so it should remain.

- [ ] **Step 5: Manual verification (asset loads at runtime)**

Run: `flutter run` (or launch via the project's run skill) on a simulator, observe the login screen.
Expected: warm paper background (not the old near-black `#101114`); the "Lumen" wordmark and "Welcome back" card title render in the Fraunces serif; no red error screen and no console `Unable to load asset: assets/fonts/...` message. (This is the real check that the vendored `.ttf` files resolve — `flutter test` does not rasterize bundled fonts, so unit tests cannot catch a missing asset; this step does.)

- [ ] **Step 6: Commit**

```bash
git add lib/app.dart test/theme/lumen_theme_smoke_test.dart
git commit -m "feat(theme): wire app.dart to LumenTheme.light(), drop purple seed"
```

---

## Self-Review

**Spec coverage:**
- `lumen_colors.dart` (13-field palette + `entityColors` + `copyWith`/`lerp` + `context.lumenColors`) → Task 1 ✓
- `lumen_text.dart` (15 slots, `_fraunces` helper, ss01-only, explicit `fontVariations`, `eyebrow`) → Task 2 ✓
- `lumen_theme.dart` (`LumenSurface` radius+shadow, all ColorScheme roles incl. the 12 `*Fixed`) → Task 3 ✓
- Variable fonts vendored + `fonts:` block → Task 4 ✓
- `app.dart` swap (drop purple seed / near-black scaffold) → Task 5 ✓
- Smoke test (extension resolves, boots) → Task 5 ✓
- Non-goals (dark mode, retheming other screens, mono font) → explicitly not built; dark-mode extension points (`copyWith`/`lerp`) are present ✓

**Placeholder scan:** No `TBD`/`TODO`/"add error handling"/"similar to Task N". `copyWith` and `lerp` are written out in full for both extensions (the spec's `/* ... */` elisions are expanded). The full `ColorScheme(...)` is reproduced completely. ✓

**Type consistency:** `LumenColors` field names match across the test, the class, and `LumenTheme`'s `colors.*` reads. `LumenText.textTheme({foreground, mutedForeground})` signature matches its one call site in `LumenTheme.light()`. `LumenSurface` field names (`radiusLg`, `shadowPaper`, …) match between class, `static final light`, and the Task 3 test. `entityColors` keyed by `EntityType` (verified all 9 enum values exist in `lib/models/entity.dart`). `context.lumenColors` getter defined in Task 1, used in Task 5. ✓

**Known platform caveat documented inline:** `extensions: const [...]` may need `const` dropped (LumenSurface.light is `final`); the `dart:ui` import covers `FontVariation`/`FontFeature`; `flutter test` can't verify font rasterization so Task 5 Step 5 adds a manual runtime check. All noted at their step.

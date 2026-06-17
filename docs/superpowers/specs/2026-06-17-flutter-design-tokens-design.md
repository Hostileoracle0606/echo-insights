# Flutter Design Tokens (Phase 2 of the Web↔Flutter Visual Parity Initiative)

## Context

Lumen exists today as a web app (TanStack Start) with a deliberate "warm paper-and-ink" visual identity, fully documented in [`docs/visual-system-audit.md`](../../visual-system-audit.md). A separate Flutter/iOS port (`lib/`, `ios/`) exists in demo state and currently looks nothing like it: `lib/app.dart` hardcodes a generic Material purple seed (`0xFF7A6FF0`) on a near-black scaffold (`0xFF101114`), and individual screens (`graph_canvas.dart`, `node_glyph.dart`, `transcript_overlay.dart`, `graph_legend.dart`, `journal_screen.dart`) each carry their own unrelated dark/neon palettes with ad-hoc `Colors.white.withValues(alpha: ...)` overlays.

Bringing the Flutter app to visual parity with the web app is a 10-phase initiative:

1. Create a web→Flutter component parity map
2. **Build shared design tokens (this spec)** — `lib/theme/lumen_colors.dart`, `lumen_text.dart`, `lumen_theme.dart`, wired into `lib/app.dart`
3. Retheme current screens (`journal_screen.dart`, `transcript_overlay.dart`, `graph_legend.dart`, `graph_canvas.dart`, `node_glyph.dart`) onto the new tokens
4. Split `journal_screen.dart` into named components (`JournalTopBar`, `GraphControlCluster`, `LiveActivityPill`, `VoiceDock`, `EntityDetailSheet`)
5. Implement the full voice dock (idle/connecting/listening/speaking/thinking/typing states, transcript preview, mute/speaker, mic, amber pulse)
6. Graph parity (entity palette consumption, glyph meanings, relation strokes, active-node treatment, selection)
7. Entity detail bottom sheet matching the web sidebar's information
8. Auth screens fully on-system (beyond the automatic `Theme.of(context)` cascade)
9. Motion parity (mic pulse, agent-speaking pulse, upsert pop, transcript rise, dock easing)
10. Screenshot verification against `docs/lumen-iphone-17-ui.html`

**This spec covers Phase 2 only.** Phases 1 and 3–10 are separate future work, each to be brainstormed and planned in its own cycle once the phase before it has landed — designing the voice dock's state machine or graph parity now, before tokens exist, would be premature.

## Goals

- Create `lib/theme/lumen_colors.dart`, `lib/theme/lumen_text.dart`, `lib/theme/lumen_theme.dart` translating the web's light-mode tokens into Flutter constants.
- Wire `lib/app.dart` to use the new theme, removing the purple seed and near-black scaffold.
- Leave a clear extension point for a dark variant (deferred — see Non-goals).

## Non-goals

- **Dark mode.** The web app has a complete `.dark` token set, but the current Flutter app has no light path at all — light (the paper-and-ink identity) ships first. `LumenColors` and `LumenSurface` are structured so a `.dark` instance can be added later without changing call sites, but that instance is not built in this phase.
- **Retheming existing screens.** `graph_canvas.dart`, `node_glyph.dart`, `transcript_overlay.dart`, `graph_legend.dart`, and `journal_screen.dart` keep their current hardcoded colors after this phase. They consume the new tokens in Phase 3. (Login/signup screens already read `Theme.of(context).textTheme`/`colorScheme` directly, so they inherit the new look automatically as a side effect of this phase — no extra work needed for them.)
- **Component splitting, voice dock, graph parity, motion.** Phases 4–9, untouched here.

## Architecture: `ThemeExtension`

`LumenColors` and a second small extension, `LumenSurface` (radius + shadow), extend Flutter's `ThemeExtension<T>` — the idiomatic pattern for a bespoke design system that doesn't map cleanly onto Material's vocabulary (no Material slot exists for `amber-soft`, `sage`, `shadow-paper`, or the grain texture). Both also populate a real `ColorScheme` derived from the same values, so stock Material widgets (`TextField`, `ElevatedButton`, etc.) auto-theme correctly without per-widget overrides. Access pattern: `Theme.of(context).extension<LumenColors>()!`, exposed via a `BuildContext` convenience getter.

This was chosen over two alternatives: plain `static const` classes (simplest, but colors aren't reachable via `Theme.of(context)` and dark mode later would mean threading `Brightness` checks through every call site instead of swapping one extension instance), and forcing every token into existing `ColorScheme` slots (maximum stock-widget compatibility, but lossy — several tokens have no Material home, and the audit's vocabulary gets renamed away, complicating future web↔Flutter diffing).

## `lib/theme/lumen_colors.dart`

`LumenColors extends ThemeExtension<LumenColors>`. All values computed via exact OKLCH→linear-sRGB conversion (Björn Ottosson's matrices — CSS Color 4 spec), not eyeballed; each constant carries its source `oklch()` string as a trailing comment for traceability back to `styles.css`.

```dart
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
    required this.paper, required this.ink, required this.amber,
    required this.amberSoft, required this.sage, required this.card,
    required this.secondary, required this.border, required this.input,
    required this.muted, required this.mutedForeground,
    required this.destructive, required this.destructiveForeground,
  });

  static const light = LumenColors(
    paper:               Color(0xFFF9F5EC), // oklch(0.97 0.012 85)
    ink:                 Color(0xFF17100C), // oklch(0.18 0.015 50)
    amber:               Color(0xFFEB881F), // oklch(0.72 0.16 60)
    amberSoft:           Color(0xFFF2D1AD), // oklch(0.88 0.06 70)
    sage:                Color(0xFF527D65), // oklch(0.55 0.06 160)
    card:                Color(0xFFFEFBF6), // oklch(0.99 0.008 85)
    secondary:           Color(0xFFEAE4DA), // oklch(0.92 0.015 80)
    border:              Color(0xFFD5CCC1), // oklch(0.85 0.018 75)
    input:               Color(0xFFDDD7CD), // oklch(0.88 0.015 80)
    muted:               Color(0xFFECE7DF), // oklch(0.93 0.012 80)
    mutedForeground:     Color(0xFF564B42), // oklch(0.42 0.02 60)
    destructive:         Color(0xFFCC272E), // oklch(0.55 0.2 25)
    destructiveForeground: Color(0xFFF8F8F8), // oklch(0.98 0 0)
  );

  // Entity/graph node palette — ported 1:1 from the web's graph-view.tsx
  // TYPE_COLORS (already plain hex there too, for the same canvas-can't-
  // read-CSS-vars reason). Defined here so Phase 3's node_glyph.dart
  // retheme is a value swap, not a fresh design decision.
  static const Map<EntityType, Color> entityColors = {
    EntityType.person:       Color(0xFFC97B3A),
    EntityType.place:        Color(0xFF5B8A72),
    EntityType.organization: Color(0xFF7A6DC4),
    EntityType.project:      Color(0xFFC0A040),
    EntityType.event:        Color(0xFFCF6A52),
    EntityType.activity:     Color(0xFF4AA39E),
    EntityType.concept:      Color(0xFF4A7AB8),
    EntityType.emotion:      Color(0xFFB85A8A),
    EntityType.other:        Color(0xFF8A8A8A),
  };

  @override
  LumenColors copyWith({ /* one optional named param per field */ }) => LumenColors(/* ... */);

  @override
  LumenColors lerp(ThemeExtension<LumenColors>? other, double t) {
    if (other is! LumenColors) return this;
    return LumenColors(
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      // ... one Color.lerp per field
    );
  }
}

extension LumenColorsContext on BuildContext {
  LumenColors get lumenColors => Theme.of(this).extension<LumenColors>()!;
}
```

`entityColors` is keyed by the existing `EntityType` enum (`lib/models/entity.dart`), giving compile-time exhaustiveness instead of a stringly-typed lookup — the one place `lib/theme/` depends on a domain model.

## `lib/theme/lumen_text.dart`

Builds a Flutter `TextTheme` covering **all 15 slots** — `displayLarge/Medium/Small`, `headlineLarge/Medium/Small`, `titleLarge/Medium/Small`, `bodyLarge/Medium/Small`, `labelLarge/Medium/Small`. Leaving any slot undefined means it silently falls back to Flutter's default (Roboto-ish) style instead of Inter/Fraunces — exactly how `graph_canvas.dart:190`'s existing `Theme.of(context).textTheme.titleLarge` call would have kept rendering in a Material default today. Fraunces → `display*`/`headline*`, **and** `titleLarge` (see below); Inter → everything else. Fraunces gets the `ss01`/`ss02` stylistic sets via `FontFeature.stylisticSet`, matching `styles.css`'s `font-feature-settings`.

Sizes are grounded in the actual web source, not invented, with two exceptions flagged inline where no second data point exists:

```dart
class LumenText {
  LumenText._();

  static const displayFontFamily = 'Fraunces';
  static const sansFontFamily = 'Inter';

  static TextTheme textTheme({required Color foreground, required Color mutedForeground}) => TextTheme(
    // Grounded in the sidebar empty-state hero ("Voice / Journal",
    // font-display text-[40px] leading-[0.95] tracking-tight) — the one
    // place the web app goes bigger than a page headline.
    displayLarge: TextStyle(fontFamily: displayFontFamily, fontSize: 40, height: 0.95, letterSpacing: -1.0, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    // displayMedium/Small: no second hero instance observed in the web
    // app — these are an interpolated step-down, not a citation. Confirm
    // visually the first time a screen actually needs them.
    displayMedium: TextStyle(fontFamily: displayFontFamily, fontSize: 34, height: 0.98, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    displaySmall: TextStyle(fontFamily: displayFontFamily, fontSize: 28, height: 1.0, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    // Matches the auth pages' CardTitle ("Welcome back", font-display
    // text-2xl tracking-tight) — login_screen.dart already reads
    // headlineLarge today.
    headlineLarge: TextStyle(fontFamily: displayFontFamily, fontSize: 24, height: 1.0, letterSpacing: -0.6, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    // Matches the "Lumen" wordmark lockup (font-display text-xl).
    headlineMedium: TextStyle(fontFamily: displayFontFamily, fontSize: 20, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    headlineSmall: TextStyle(fontFamily: displayFontFamily, fontSize: 17, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    // Matches the entity sidebar's name heading (font-display text-2xl
    // leading-tight) — the exact role graph_canvas.dart:190 already
    // calls via textTheme.titleLarge today.
    titleLarge: TextStyle(fontFamily: displayFontFamily, fontSize: 24, height: 1.2, color: foreground,
      fontFeatures: const [FontFeature.stylisticSet(1), FontFeature.stylisticSet(2)]),
    // titleMedium/Small: no direct web citation. Defaulted to Inter per
    // the audit's "Inter does the work; Fraunces stays special"
    // principle rather than inventing a second serif size.
    titleMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 16, fontWeight: FontWeight.w500, color: foreground),
    titleSmall: TextStyle(fontFamily: sansFontFamily, fontSize: 14, fontWeight: FontWeight.w500, color: foreground),
    bodyLarge: TextStyle(fontFamily: sansFontFamily, fontSize: 15, color: foreground),
    bodyMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 13, color: foreground),
    bodySmall: TextStyle(fontFamily: sansFontFamily, fontSize: 12, color: mutedForeground),
    labelLarge: TextStyle(fontFamily: sansFontFamily, fontSize: 13, fontWeight: FontWeight.w500, color: foreground),
    labelMedium: TextStyle(fontFamily: sansFontFamily, fontSize: 12, fontWeight: FontWeight.w500, color: mutedForeground),
    labelSmall: TextStyle(fontFamily: sansFontFamily, fontSize: 11, color: mutedForeground),
  );

  // The "eyebrow" convention: tiny uppercase, wide tracking, used
  // throughout the web app as a recognizable component (section labels,
  // "Upserting" badges) rather than a generic type-scale rung. Named
  // explicitly so call sites opt in rather than overloading labelSmall.
  // Correction from the prior draft: web evidence (entity sidebar
  // section labels) shows font-semibold at this size, not font-medium.
  // Tracking varies in practice (0.14em on dense labels, 0.22em on
  // page-level labels like "Lumen Notebook") — this defaults to the more
  // common 0.14em; call sites needing the wider variant can
  // `.copyWith(letterSpacing: ...)`.
  static TextStyle eyebrow(Color color) => TextStyle(
    fontFamily: sansFontFamily,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4, // ≈0.14em at 10px
    color: color,
  );
}
```

**Font assets required.** `pubspec.yaml` currently declares no fonts. This phase adds:

- Vendored static font files (Fraunces + Inter, both OFL-licensed, sourced from Google Fonts' official repo) under `assets/fonts/`.
- A `fonts:` block in `pubspec.yaml` registering both families.
- Minimum weights to vendor: **Inter** Regular (400) and Medium (500) — covers body text and the `labelLarge`/`labelMedium`/eyebrow medium-weight uses above. **Fraunces** Regular (400) only — nothing in the audit calls for a heavier display weight; headings rely on the serif character at regular weight, not boldness.

Static files (not the `google_fonts` package) so the `ss01`/`ss02` stylistic sets render exactly as specified and the app works fully offline.

## `lib/theme/lumen_theme.dart`

Carries the radius/shadow tokens (no 4th file — colocated since this file already does `ThemeExtension` wiring) and assembles the final `ThemeData`.

```dart
@immutable
class LumenSurface extends ThemeExtension<LumenSurface> {
  final double radiusSm, radiusMd, radiusLg, radiusXl, radius2xl; // 4 / 6 / 8 / 12 / 16
  final List<BoxShadow> shadowPaper; // two-layer warm shadow, ink-tinted (6% / 8% alpha)
  final List<BoxShadow> shadowInk;   // hard 2px letterpress edge, no blur

  const LumenSurface({ required this.radiusSm, /* ... */ required this.shadowInk });

  static final light = LumenSurface(
    radiusSm: 4, radiusMd: 6, radiusLg: 8, radiusXl: 12, radius2xl: 16,
    shadowPaper: [
      BoxShadow(color: LumenColors.light.ink.withValues(alpha: 0.06), blurRadius: 2, offset: const Offset(0, 1)),
      BoxShadow(color: LumenColors.light.ink.withValues(alpha: 0.08), blurRadius: 32, offset: const Offset(0, 8)),
    ],
    shadowInk: [
      BoxShadow(color: LumenColors.light.ink.withValues(alpha: 0.9), blurRadius: 0, offset: const Offset(0, 2)),
    ],
  );

  @override
  LumenSurface copyWith({ /* ... */ }) => LumenSurface(/* ... */);

  @override
  LumenSurface lerp(ThemeExtension<LumenSurface>? other, double t) {
    if (other is! LumenSurface) return this;
    return LumenSurface(
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t)!,
      // ...
      shadowPaper: BoxShadow.lerpList(shadowPaper, other.shadowPaper, t) ?? shadowPaper,
      shadowInk: BoxShadow.lerpList(shadowInk, other.shadowInk, t) ?? shadowInk,
    );
  }
}

class LumenTheme {
  LumenTheme._();

  static ThemeData light() {
    const colors = LumenColors.light;

    // Material 3's ColorScheme has ~47 roles (including the 12
    // *Fixed/*FixedDim/on*Fixed/on*FixedVariant roles per primary/
    // secondary/tertiary, added for components that must stay the same
    // color across brightness changes). The ColorScheme.light(...)
    // convenience constructor — and ColorScheme.fromSeed(...), the thing
    // being removed from app.dart — fill every role you DON'T specify
    // with Material's own baseline (purple-ish) defaults. That's exactly
    // the bug: a screen using, say, surfaceContainerHighest or
    // tertiaryContainer would silently render in stock Material purple
    // even after this theme lands. So every role below is set
    // explicitly via the base ColorScheme(...) constructor, which makes
    // each one a required argument — the compiler enforces completeness.
    // (The *Fixed roles are technically optional on this constructor —
    // omitting them falls back to primary/secondary/tertiary rather than
    // Material purple, so it's a smaller gap than the others here — but
    // they're set explicitly anyway for the same completeness guarantee.)
    //
    // Roles with no direct web equivalent either collapse onto the
    // nearest real token (the web has exactly two surface lightness
    // steps — paper and card — so Material's five-step surfaceContainer
    // ladder collapses onto those two rather than inventing intermediate
    // tints the web never designed; likewise the *Fixed roles collapse
    // onto their *Container counterparts since Lumen has no light/dark
    // pair yet to derive a distinct "Dim" variant from — revisit once
    // dark mode exists) or are derived with a single, clearly-labeled
    // blend (errorContainer, outlineVariant). Deprecated roles
    // (background, onBackground, surfaceVariant) are intentionally
    // omitted — Material 3 superseded them with surface/surfaceContainer*/
    // onSurfaceVariant, set below.
    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: colors.ink,
      onPrimary: colors.paper,
      primaryContainer: colors.secondary,
      onPrimaryContainer: colors.ink,
      // Fixed/FixedDim collapse onto the same value as primaryContainer
      // (no distinct "dim" tint exists in Lumen's vocabulary); the
      // FixedVariant on-color uses mutedForeground rather than duplicating
      // onPrimaryFixed, since "Variant" specifically means lower-emphasis
      // text and Lumen already has a real token for that.
      primaryFixed: colors.secondary,
      primaryFixedDim: colors.secondary,
      onPrimaryFixed: colors.ink,
      onPrimaryFixedVariant: colors.mutedForeground,
      // Material's "secondary" role gets Lumen's sage accent, not
      // LumenColors.secondary (the web's --secondary neutral token,
      // used above for primaryContainer instead). The two are unrelated
      // despite the name collision — LumenColors.secondary stays
      // available via context.lumenColors.secondary for direct token
      // access without going through Material's role vocabulary.
      secondary: colors.sage,
      onSecondary: colors.paper,
      secondaryContainer: colors.muted,
      onSecondaryContainer: colors.ink,
      secondaryFixed: colors.muted,
      secondaryFixedDim: colors.muted,
      onSecondaryFixed: colors.ink,
      onSecondaryFixedVariant: colors.mutedForeground,
      // Amber is the web's --accent token; Material's tertiary slot is
      // its natural home since primary is already taken by ink.
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
      textTheme: LumenText.textTheme(foreground: colors.ink, mutedForeground: colors.mutedForeground),
      extensions: [colors, LumenSurface.light],
    );
  }
}
```

## `lib/app.dart` wiring

```diff
       theme: ThemeData(
-        colorScheme: ColorScheme.fromSeed(
-          seedColor: const Color(0xFF7A6FF0),
-          brightness: Brightness.dark,
-        ),
-        scaffoldBackgroundColor: const Color(0xFF101114),
-        useMaterial3: true,
-      ),
+      theme: LumenTheme.light(),
```

No `darkTheme`/`themeMode` added — when `MaterialApp` has no `darkTheme`, it uses `theme` regardless of system brightness, so this is a clean no-op for dark mode until that phase exists.

## Testing

One widget smoke test: pump `MaterialApp(theme: LumenTheme.light(), home: ...)`, confirm `Theme.of(context).extension<LumenColors>()` returns the expected paper/ink/amber values, and that the app boots without a missing-font/asset exception (catches a misconfigured `pubspec.yaml` fonts block immediately). Full visual correctness is verified later against `docs/lumen-iphone-17-ui.html` per Phase 10 — out of scope here.

## File summary

| File                          | Contains                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| `lib/theme/lumen_colors.dart` | `LumenColors` (`ThemeExtension`), light palette, `entityColors` map, `BuildContext` getter |
| `lib/theme/lumen_text.dart`   | `LumenText`: `TextTheme` builder + `eyebrow()`                                             |
| `lib/theme/lumen_theme.dart`  | `LumenSurface` (`ThemeExtension`, radius+shadow), `LumenTheme.light()`                     |
| `lib/app.dart`                | Swap `ThemeData(...)` for `LumenTheme.light()`                                             |
| `pubspec.yaml`                | Add `fonts:` block                                                                         |
| `assets/fonts/`               | Vendored Fraunces + Inter static files                                                     |
| `test/`                       | One theme smoke test                                                                       |

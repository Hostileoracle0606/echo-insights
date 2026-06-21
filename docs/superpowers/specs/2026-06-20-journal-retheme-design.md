# Journal Screen Retheme — Cycle A (static paper journal) — Design

## Context

The Lumen iOS/Flutter journal screen is still the original dark/neon build, even though the token layer (`LumenColors`/`LumenText`/`LumenSurface`) and the entity-note sheet already ship on the warm paper palette. The screen a user lands on therefore contradicts both the [visual-system audit](../visual-system-audit.md) and the approved iPhone-17 mockups — and it visibly disagrees with itself (graph nodes are neon blue via `node_glyph`, while the entity sheet shows the same entity's dot in terracotta via `LumenColors.entityColors`).

This is **Cycle A** of the journal retheme: bring the *static* journal screen to the idle mockup — paper background, warm graph, the Lumen wordmark top bar, the idle voice capsule, and tokenized overlays. The *living* voice dock (transcript drawer, thinking/upsert states, mercury goo, pul/motion) is **Cycle B**, a separate spec/plan that builds on the dock placement landed here.

## Goal

Make `JournalScreen` and its sub-widgets render on the paper-and-ink tokens so the resting screen matches the idle journal mockup, and unify the entity palette to one source.

## Non-goals (Cycle B or later)

- Voice-dock morph: transcript drawer, listening/speaking/thinking states, upsert activity pill, mercury goo, amber pulses beyond the existing simple ring.
- Functional mute (speaker) and keyboard (text input) controls — rendered in the dock but inert this pass.
- Top-bar overflow menu (`⋯`: export / clear / wiki-granular mode).
- Notebooks dashboard; auth screens.
- A true CSS-style paper-grain dot field in the canvas (stretch — see Graph canvas).

## Components & changes

### 1. Top bar — new `JournalTopBar`
Replace the dark top-center `_StatusPill` (in `journal_screen.dart`) with a full-width top bar matching the mockup: **left** a brand cluster — an `ink` rounded tile (radius 10) holding a Sparkles icon in `paper`, then "Lumen" in Fraunces (`textTheme.headlineMedium`) over a "voice · graph" subtitle (`mutedForeground`); **right** a stats pill (`card` bg, `border`, `StadiumBorder`, `shadowPaper`) showing `{entityCount} · {relationCount}` plus the session status word, in `mutedForeground`/`ink`. No `⋯` menu this pass.

### 2. Graph canvas retheme — `graph_canvas.dart`
The `_GraphPainter` is a `CustomPainter`, so it cannot read `context.lumenColors`; `GraphCanvas.build` reads the tokens and passes them into the painter constructor. Color mapping:

| Element (current) | New |
|---|---|
| bg gradient `0xFF121318/222238/131A1A` | solid `paper` |
| edges `Colors.white @0.18` | `ink @0.18` |
| node stroke `Colors.white @0.4` | `ink @0.12` |
| node label `Colors.white @0.86` | `ink` |
| ambient grid `Colors.white @0.035` | `ink @0.04` |
| node fill `colorForEntityType` (neon) | `colorForEntityType` (warm — see §3) |

The faint ambient grid stays (recolored) as the subtle texture. A finer paper-grain dot field is a **stretch**: if added, render it as a static tiled layer *behind* the `CustomPaint` (not inside the per-frame painter, whose `shouldRepaint` is always true) to avoid per-frame cost.

### 3. Entity palette unification — `node_glyph.dart`
`node_glyph.dart` currently defines its own neon `entityTypeColors`. Repoint `colorForEntityType` at `LumenColors.entityColors` (the warm palette the entity sheet already uses) so the graph, the legend, and the sheet all draw from **one** source. This resolves the audit's F3 finding and the blue-vs-terracotta inconsistency in a single edit, and automatically reskins the graph nodes (§2) and the legend (§6).

### 4. Idle voice dock — new `VoiceDock` (replaces `mic_button.dart`)
A paper capsule (`card` bg, `border`, `rounded` 32, `shadowPaper`) holding a centered three-control row: a mute control (`Icons.volume_up`, `mutedForeground`), the **mic** (an `amber` filled circle, `Icons.mic_rounded` in white; `Icons.stop_rounded` when live; spinner when connecting/ending), and a keyboard control (`Icons.keyboard`, `mutedForeground`). The mic keeps the current session wiring (`onPressed` → start/stop) and the existing expanding ring animation, recolored to `amber`. Mute and keyboard are rendered but inert (Cycle B). This supersedes `mic_button.dart`, which is deleted; its `AnimationController` pulse logic moves into `VoiceDock`.

### 5. Transcript overlay retheme — `transcript_overlay.dart`
Swap the dark container for `card` bg + `border` + `shadowPaper`, text in `ink`. Keep the show-for-4s fade behavior unchanged. (Cycle B folds this into the dock drawer; for now it stays the floating overlay, just paper.)

### 6. Graph legend retheme — `graph_legend.dart`
Swap `Colors.black @0.28` / `Colors.white @0.12` for `card` bg + `border`; its `NodeGlyph` rows pick up the warm palette automatically from §3. Reposition so it doesn't collide with the new top bar (top-right, below the top-bar row).

## Architecture notes

- `JournalScreen` stays a `ConsumerWidget`; its `Stack` keeps `GraphCanvas` at the back, with `JournalTopBar` (top, full width, `SafeArea`), `GraphLegend` (below it), `TranscriptOverlay` (center), and `VoiceDock` (bottom-center, `SafeArea`).
- New widgets `JournalTopBar` and `VoiceDock` live in `lib/screens/journal/`, each a focused file. They read tokens via `context.lumenColors` / `Theme.of(context).textTheme`.
- No provider, data-model, or session-logic changes — this is presentation only. `VoiceDock` takes the same `status` + `onPressed` props `MicButton` did.

## File summary

| File | Change |
|---|---|
| `lib/screens/journal/journal_top_bar.dart` | Create — brand cluster + stats pill |
| `lib/screens/journal/voice_dock.dart` | Create — idle paper capsule + mic/mute/keyboard, amber pulse |
| `lib/screens/journal/journal_screen.dart` | Modify — use `JournalTopBar` + `VoiceDock`; delete `_StatusPill`; reposition legend |
| `lib/screens/journal/graph_canvas.dart` | Modify — pass tokens into `_GraphPainter`; recolor bg/edges/strokes/labels/ambient |
| `lib/widgets/node_glyph.dart` | Modify — `colorForEntityType` → `LumenColors.entityColors` |
| `lib/screens/journal/transcript_overlay.dart` | Modify — paper card |
| `lib/screens/journal/graph_legend.dart` | Modify — paper card |
| `lib/screens/journal/mic_button.dart` | Delete — replaced by `voice_dock.dart` |

## Testing

- `node_glyph_test.dart` (unit): `colorForEntityType(t) == LumenColors.entityColors[t]` for every `EntityType` — locks the single-palette reconciliation.
- `journal_top_bar_test.dart` (widget): given counts, renders "Lumen" and `"{n} · {m}"`; pumped under `LumenTheme.light()`.
- `voice_dock_test.dart` (widget): renders the mic; tapping it fires `onPressed`; shows `Icons.stop_rounded` when `status == live`, a spinner when `connecting`.
- `journal_screen_test.dart` (smoke): builds under `ProviderScope` (seeded `JournalNotifier`) + `LumenTheme.light()` without throwing; finds "Lumen".
- Manual: `flutter run` on the iPhone 17 simulator — the journal screen is paper (not dark), nodes are warm/terracotta-family and match the entity-sheet dots, the top bar shows the Lumen wordmark + stats pill, the bottom shows the paper voice capsule with an amber mic.

Verification gate: `flutter analyze lib/ test/` → `No issues found!` and `flutter test` green (scoped to exclude the pre-existing `tool/` lint).

## Edge cases

- Empty graph (no entities): canvas renders paper with no nodes; top bar shows `0 · 0`; no crash.
- Long entity names: existing label clamp/ellipsis in the painter is retained.
- `CustomPainter` token access: tokens are constructor args (painters can't read `InheritedWidget`s); `GraphCanvas.build` is the single read point.

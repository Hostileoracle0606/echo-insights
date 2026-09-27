# Code review: transcript mode (pill E)

Date: 2026-09-26. Code snapshot: `7badfb4` on `feat/transcript-mode`, reviewed
before merge into `main`.

This document records the findings from the code review of the pill-E dock
and transcript-mode page transition, and the fixes applied for each before
merging. Source links are relative to this file; commit IDs pin the reviewed
and fixed code.

## Findings

### 1. Animation status listeners leaked on every rebuild

**File:** `lib/screens/journal/transcript_page.dart` (`_Staggered`, `_Empty`)
and `lib/screens/journal/journal_screen.dart` (`_transcriptLayer`).

**Description:** Each of these built a new `CurvedAnimation` inline, in
`build()`, every time the widget rebuilt. `CurvedAnimation`'s constructor
registers a status listener on its `parent` animation
(`parent.addStatusListener(...)`); that listener is only removed by calling
`dispose()` on the `CurvedAnimation` itself. Because these were local
values created fresh on each `build()` and never held onto or disposed, the
listener from every prior build stayed registered on the shared, long-lived
`_page` controller.

**Failure scenario:** In transcript view during a live voice session, every
streaming transcript chunk triggers a provider update, which rebuilds
`JournalScreen` and every visible `_Staggered`-wrapped turn. Each rebuild
added roughly ten new listeners to `_page` (one per visible turn, plus the
day header and the page-slide layer) that were never released. Over a
20-minute session this reaches tens of thousands of dangling listeners.
Beyond the memory growth, every forward/reverse of `_page` (i.e. every
graph ⇄ transcript switch) walks its full listener list, so view switches
would keep getting slower for the life of the session.

**Fix applied** (commit `66eb3a1`): `_Staggered` was changed from a
`StatelessWidget` to a `StatefulWidget` (`_StaggeredState`) that builds its
`CurvedAnimation` once in `initState()`/`didUpdateWidget()` and disposes it
in `dispose()`. `_Empty`'s ad hoc fade was replaced by reusing `_Staggered`
(rank 1), removing the second inline `CurvedAnimation`. In
`JournalScreen`, the page-slide `CurvedAnimation` was hoisted out of
`_transcriptLayer()` into a `late final` field (`_slide`) built once at
field-initialization time and disposed alongside `_page` in `dispose()`.

### 2. Highlight regex recompiled per term, per turn, per rebuild

**File:** `lib/logic/entity_highlighter.dart` (`highlightRuns`).

**Description:** `highlightRuns` compiled a fresh, unicode-aware `RegExp`
for every entity term on every call. It is called once per visible
transcript turn (and once for the dock's live drawer) on every rebuild.

**Failure scenario:** A notebook with around 300 entities and ~10 visible
turns compiles roughly 3,000 regexes per transcript chunk; several chunks
arrive per second while someone is speaking. On older devices this was
enough to drop frames during the page transition and during live word-by-
word updates.

**Fix applied** (commit `66eb3a1`): patterns are now compiled once per
distinct entity name and cached in a module-level `Map<String, RegExp>`
(`_patternFor`), with a simple size cap (cleared past 4096 entries) so the
cache cannot grow unbounded across notebooks. The cache is safe to share
across rebuilds because the compiled pattern for a given name never
changes.

## Verification

- `flutter analyze`: no issues, before and after the fixes.
- `flutter test`: 219/219 passing, before and after the fixes (the fixes
  are non-behavioral — no test needed to change).

## Commit and merge record

| Commit | Purpose |
| --- | --- |
| `7badfb4` | Pill E dock (symmetric two-tier card) and transcript mode. |
| `66eb3a1` | Review fixes: dispose transcript curves, cache highlight patterns. |
| `6897e08` | Merge `feat/transcript-mode` into `main`. |

# Entity Note Viewer (Obsidian-like reading surface) — Design

## Context

Lumen's Flutter/iOS port renders a knowledge graph; tapping a node currently opens a small modal bottom sheet ([`graph_canvas.dart:131`](../../../lib/screens/journal/graph_canvas.dart), `_EntitySheet`) showing the entity's name, type, and description. The web app's [obsidian-export.ts](../../../src/lib/obsidian-export.ts) already defines the full "note" model for an entity — a page with a description, a `## Connections` section (`[[wikilinks]]` to related entities), a `## Mentioned by` backlinks section, and recent mentions.

This feature enriches that bottom sheet into a **navigable entity note**: it stays a modal bottom sheet, but gains tappable `[[wikilinks]]` and an internal back stack, giving the Obsidian-like "interlinked notes + backlinks" experience. It deliberately stops there — no separate Notes mode, map-of-content home, or daily notes (those were explored as mockups and dropped). The graph remains the single home; the sheet is the entity surface, enriched and traversable in place.

This supersedes the parity plan's Phase 7 ("Entity detail bottom sheet") with a richer, navigable version of the same surface.

## Goal

Enrich the entity bottom sheet into a navigable `EntityNoteSheet` that reads from `JournalState` and lets the user traverse entity → entity via tappable relation links — swapping the sheet's content in place and tracking an internal back stack, while keeping the modal-bottom-sheet form.

## Non-goals (explicitly out of scope)

- **No Notes mode / `Graph | Notes` toggle, no map-of-content home, no daily notes.** Dropped after mockup review.
- **No editing.** Read-only.
- **No full-page route, no stacked sheets.** A single modal bottom sheet that swaps its content in place — not a pushed `Navigator` page, and not a new sheet stacked per link.
- **No markdown.** The sheet renders native Flutter widgets directly from `JournalState` — it does not generate or parse markdown. `obsidian-export.ts` remains the separate *export* path; this is a parallel *read* path over the same structured data.
- **No full-text search, no folders/file-tree, no time-anchor deep links.**
- **Web app unchanged.** This is the Flutter/iOS app only.

## Where it lives & navigation

- **Entry:** tap a graph node → `showModalBottomSheet` presenting `EntityNoteSheet(entityId)` (the existing call site in `_handleTap`, retheme + richer body). The sheet holds its own navigation history seeded with the tapped `entityId`.
- **Traversal (in place):** tapping any relation link (a `[[wikilink]]`) appends the target `entityId` to the sheet's internal history and rebuilds the sheet body for that entity — the sheet itself does not move or restack. A leading **back chevron** in the sheet header pops the internal history (Maya → Atlas → Lisbon → back → back), and is hidden when at the root entity.
- **Dismiss / locate:** swipe-down or tapping the scrim dismisses the whole sheet regardless of history depth (standard `showModalBottomSheet` behavior); a trailing close (`×`) does the same. An optional "locate in graph" action dismisses the sheet and centers the current entity's node. (Locate-in-graph is a nice-to-have; back chevron + dismiss are required.)
- **Surface form:** a single draggable modal bottom sheet (`DraggableScrollableSheet` inside `showModalBottomSheet` — peek small, drag up to read longer notes). The voice dock belongs to the journal screen beneath and is not part of the sheet.
  - **Scroll plumbing (required):** present with `showModalBottomSheet(isScrollControlled: true)` — without it the sheet is height-capped at ~half screen and can't expand. The sheet body's single scrollable (a `ListView`/`CustomScrollView` holding the sections) **must** be driven by the `scrollController` that `DraggableScrollableSheet.builder` provides, so drag-to-expand and content scroll hand off as one gesture. Suggested `DraggableScrollableSheet` sizing: `initialChildSize: 0.55`, `minChildSize: 0.4`, `maxChildSize: 0.92`. Set `useSafeArea: true` so the expanded sheet clears the status bar / Dynamic Island.

## Sheet content (all derived from `JournalState`)

Given the current `entityId` (the last id in the sheet's internal history), read `state.entities[entityId]` plus the relations/entries that reference it. Sections, top to bottom:

1. **Header** — a back chevron (shown only when history depth > 1) and a close `×`; below them, a type eyebrow (`LumenText.eyebrow`) preceded by a `LumenColors.entityColors[type]` dot; the entity `name` in `Fraunces` (`textTheme.titleLarge`); meta line `"{mentions} mentions · last {relativeTime(lastSeen)}"`.
2. **Description** — `entity.description` as body text. If null/empty, the section is omitted. *(See wikilink note below — the description is plain prose; inline linkification is a stretch goal, not v1.)*
3. **Connections** (outbound) — active relations where `relation.source == entityId`: each row reads `"{label, _underscores→spaces_} → [[target.name]]"`, the target rendered as a tappable wikilink. Excludes `!relation.isActive` (superseded) and rows whose target entity is missing. Self-relations (`source == target == entityId`) belong here (the entity *has* the relation) and render once with a **non-tappable** self name.
4. **Mentioned by** (backlinks) — active relations where `relation.target == entityId` **and `relation.source != entityId`**: `"[[source.name]] — {label}"`, source tappable. The `source != entityId` guard is what keeps a self-relation from also appearing here — it lives only under Connections.
5. **Recent mentions** — `state.entries` where `entityIds.contains(entityId)`, newest first (cap ~12), each showing a text snippet + relative time. **Read-only snippets** (not links — daily-note pages were dropped, so there is no navigation target).

Sections 3–5 are omitted when empty.

### Wikilinks — what is and isn't linkable (important)

The reliable wikilinks are the **structured** ones in Connections and Mentioned-by: those come from `Relation.source`/`target`, which are already entity ids, so resolution is exact. Tapping one appends that id to the sheet's internal history (in-place swap). **Inline wikilinks inside the description prose are a stretch goal**, because `entity.description` is free text from the extractor — making "Atlas" inside the prose tappable requires scanning the description for known entity names (`name → entityId`, case-insensitive, longest-match-first to avoid overlaps). v1 ships the structured links only; the mockup's inline-description links are deferred behind a `linkifyDescription` flag (default off) so we don't ship fuzzy name-matching prematurely.

## Components & files

| File | Responsibility |
|---|---|
| Create: `lib/screens/journal/entity_note_sheet.dart` | `EntityNoteSheet(entityId)` — a `ConsumerStatefulWidget` that owns the internal history (`List<String> _history`, current = `_history.last`), reads `journalProvider`, builds the sections for the current entity inside a `DraggableScrollableSheet.builder`, and passes the builder's `scrollController` to the single scrollable that holds the sections. Wikilink taps `setState`-append to `_history`; the back chevron pops it. |
| Create: `lib/screens/journal/wikilink.dart` | A small `WikiLink` widget/text-span: renders an entity name as ink text with an amber underline (`LumenColors.amber`), tappable → callback with `entityId`. |
| Modify: `lib/screens/journal/graph_canvas.dart:131` | `_handleTap` keeps `showModalBottomSheet` but presents `EntityNoteSheet(hit.entity.id)` with `isScrollControlled: true` and `useSafeArea: true` (paper-themed), instead of the dark `_EntitySheet`; delete `_EntitySheet` (its content moves into the sheet, rebuilt on tokens). |

All surfaces use the Phase-2/3 token layer (`LumenColors`, `LumenText`, `context.lumenColors`) — **not** the old hardcoded `0xFF191B20` dark sheet color (the F1 audit finding). The sheet therefore depends on the paper theme being in place; if Phase 3 (screen retheme) hasn't landed, the sheet still brings its own token usage and renders correctly on `LumenTheme.light()`.

## Data flow

`EntityNoteSheet` is a `ConsumerStatefulWidget` reading the current `JournalState` from `journalProvider`. State is the navigation history: `List<String> _history` (seeded with the tapped id); the displayed entity is `_history.last`. A wikilink tap does `setState(() => _history.add(targetId))`; the back chevron does `setState(() => _history.removeLast())`. For the current entity it computes outbound/inbound relation lists and the mentions list with simple in-memory filters (`relations.values.where(...)`, `entries.where(...)`). No new providers, no persistence, no network. If the current id is absent from state (e.g. cleared mid-traversal), the sheet shows a minimal "Note unavailable" body; the same chrome rules apply — the back chevron is shown only when history depth > 1 (so a missing *root* entity shows no chevron), and the close `×` is always available to dismiss.

## Testing

Widget tests pump `EntityNoteSheet` wrapped in `ProviderScope`. Because `journalProvider` is a `NotifierProvider<JournalNotifier, JournalState>`, the test seam is a notifier override, not a value override:

```dart
class _SeededJournalNotifier extends JournalNotifier {
  _SeededJournalNotifier(this._seed);
  final JournalState _seed;
  @override
  JournalState build() => _seed;
}

ProviderScope(
  overrides: [journalProvider.overrideWith(() => _SeededJournalNotifier(fixedState))],
  child: /* sheet under test */,
)
```

If `JournalNotifier.build()` does I/O (e.g. it `ref.read`s `supabaseServiceProvider`), the subclass overriding `build()` to return `_seed` bypasses it — no Supabase stub needed. With that seam:

1. Header renders the entity name and `mentions` count; the back chevron is absent at history root.
2. Connections lists exactly the active outbound relations (a superseded relation is excluded).
3. Mentioned-by lists active inbound relations.
4. Recent mentions shows entry snippets for entries containing the entity, newest first.
5. Tapping a Connections wikilink swaps the sheet body to the target entity (target name now shown) and reveals the back chevron; tapping the back chevron restores the origin entity.
6. An entity with no description/relations/entries renders header-only without throwing.
7. A self-relation (`source == target == entityId`) appears once under Connections and not under Mentioned-by, and its self name is non-tappable (tapping does not change the displayed entity).

## Edge cases

- Superseded relations (`!isActive`) excluded everywhere.
- Self-relations (`source == target`) render once under **Connections only** (Mentioned-by's `source != entityId` guard excludes them); the self name is non-tappable so a tap can't push a duplicate.
- Missing target/source entity for a relation → that row is skipped.
- No description / no relations / no entries → respective sections omitted; header always renders.
- Back chevron hidden when history depth is 1; swipe-down / scrim / `×` dismisses the sheet at any depth.
- Tapping the wikilink for the entity already shown is a no-op (don't push a duplicate onto the history).
- Deep internal histories are bounded only by how many links the user follows; no special handling needed.

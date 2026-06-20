# Entity Note Viewer (Obsidian-like reading surface) — Design

## Context

Lumen's Flutter/iOS port renders a knowledge graph; tapping a node currently opens a small modal bottom sheet ([`graph_canvas.dart:131`](../../../lib/screens/journal/graph_canvas.dart), `_EntitySheet`) showing the entity's name, type, and description. The web app's [obsidian-export.ts](../../../src/lib/obsidian-export.ts) already defines the full "note" model for an entity — a page with a description, a `## Connections` section (`[[wikilinks]]` to related entities), a `## Mentioned by` backlinks section, and recent mentions.

This feature promotes that bottom sheet into a **navigable entity note**: a full-page reading surface with tappable `[[wikilinks]]` and a back stack, giving the Obsidian-like "interlinked notes + backlinks" experience. It deliberately stops there — no separate Notes mode, map-of-content home, or daily notes (those were explored as mockups and dropped). The graph remains the single home; the note is simply the entity sheet, expanded and traversable.

This supersedes the parity plan's Phase 7 ("Entity detail bottom sheet") with a slightly richer, navigable surface.

## Goal

Replace the entity bottom sheet with a pushed-route `EntityNotePage` that reads from `JournalState` and lets the user traverse entity → entity via tappable relation links, with a native back stack.

## Non-goals (explicitly out of scope)

- **No Notes mode / `Graph | Notes` toggle, no map-of-content home, no daily notes.** Dropped after mockup review.
- **No editing.** Read-only.
- **No markdown.** The page renders native Flutter widgets directly from `JournalState` — it does not generate or parse markdown. `obsidian-export.ts` remains the separate *export* path; this is a parallel *read* path over the same structured data.
- **No full-text search, no folders/file-tree, no time-anchor deep links.**
- **Web app unchanged.** This is the Flutter/iOS app only.

## Where it lives & navigation

- **Entry:** tap a graph node → `Navigator.push` an `EntityNotePage(entityId)` over the journal screen (replacing the current `showModalBottomSheet` call in `_handleTap`).
- **Traversal:** tapping any relation link (a `[[wikilink]]`) inside the page pushes another `EntityNotePage` for the target entity. The system/back chevron pops the stack — standard iOS push/pop, so deep chains (Maya → Atlas → Lisbon → back → back) work for free.
- **Dismiss / locate:** a leading back chevron pops one level; an optional trailing "locate in graph" action pops the whole stack and centers that node in the graph. (Locate-in-graph is a nice-to-have; the back chevron is required.)
- **Surface form:** a full-height pushed route (not a stacked bottom sheet) — clean back-stack semantics for chained traversal. The voice dock belongs to the journal screen beneath and is not part of this page.

## Page content (all derived from `JournalState`)

Given an `entityId`, read `state.entities[entityId]` plus the relations/entries that reference it. Sections, top to bottom:

1. **Header** — type eyebrow (`LumenText.eyebrow`) preceded by a `LumenColors.entityColors[type]` dot; the entity `name` in `Fraunces` (`textTheme.titleLarge`); meta line `"{mentions} mentions · last {relativeTime(lastSeen)}"`.
2. **Description** — `entity.description` as body text. If null/empty, the section is omitted. *(See wikilink note below — the description is plain prose; inline linkification is a stretch goal, not v1.)*
3. **Connections** (outbound) — active relations where `relation.source == entityId`: each row reads `"{label, _underscores→spaces_} → [[target.name]]"`, the target rendered as a tappable wikilink. Excludes `!relation.isActive` (superseded) and rows whose target entity is missing.
4. **Mentioned by** (backlinks) — active relations where `relation.target == entityId`: `"[[source.name]] — {label}"`, source tappable.
5. **Recent mentions** — `state.entries` where `entityIds.contains(entityId)`, newest first (cap ~12), each showing a text snippet + relative time. **Read-only snippets** (not links — daily-note pages were dropped, so there is no navigation target).

Sections 3–5 are omitted when empty.

### Wikilinks — what is and isn't linkable (important)

The reliable wikilinks are the **structured** ones in Connections and Mentioned-by: those come from `Relation.source`/`target`, which are already entity ids, so resolution is exact. **Inline wikilinks inside the description prose are a stretch goal**, because `entity.description` is free text from the extractor — making "Atlas" inside the prose tappable requires scanning the description for known entity names (`name → entityId`, case-insensitive, longest-match-first to avoid overlaps). v1 ships the structured links only; the mockup's inline-description links are deferred behind a `linkifyDescription` flag (default off) so we don't ship fuzzy name-matching prematurely.

## Components & files

| File | Responsibility |
|---|---|
| Create: `lib/screens/journal/entity_note_page.dart` | `EntityNotePage(entityId)` — reads `journalProvider`, builds the five sections, handles wikilink taps (`Navigator.push` self). |
| Create: `lib/screens/journal/wikilink.dart` | A small `WikiLink` widget/text-span: renders an entity name as ink text with an amber underline (`LumenColors.amber`), tappable → callback with `entityId`. |
| Modify: `lib/screens/journal/graph_canvas.dart:131` | `_handleTap` pushes `EntityNotePage` instead of `showModalBottomSheet`; delete the dark `_EntitySheet` (its content moves into the page, rebuilt on tokens). |

All surfaces use the Phase-2/3 token layer (`LumenColors`, `LumenText`, `context.lumenColors`) — **not** the old hardcoded `0xFF191B20` dark sheet color. This page therefore depends on the paper theme being in place; if Phase 3 (screen retheme) hasn't landed, the page still brings its own token usage and renders correctly on `LumenTheme.light()`.

## Data flow

`EntityNotePage` is a `ConsumerWidget` reading the current `JournalState` from `journalProvider`. It computes outbound/inbound relation lists and the mentions list with simple in-memory filters (`relations.values.where(...)`, `entries.where(...)`). No new providers, no persistence, no network. If the entity id is absent from state (e.g. cleared mid-navigation), the page shows a minimal "Note unavailable" state and offers back.

## Testing

Widget tests pumping `EntityNotePage` wrapped in `ProviderScope` with an overridden `journalProvider` exposing a small fixed `JournalState`:

1. Header renders the entity name and `mentions` count.
2. Connections lists exactly the active outbound relations (a superseded relation is excluded).
3. Mentioned-by lists active inbound relations.
4. Recent mentions shows entry snippets for entries containing the entity, newest first.
5. Tapping a Connections wikilink pushes a new route for the target entity (assert via a `NavigatorObserver` or that the target's name appears).
6. An entity with no description/relations/entries renders header-only without throwing.

## Edge cases

- Superseded relations (`!isActive`) excluded everywhere.
- Self-relations (`source == target`) shown once, not double-counted; the wikilink to self is rendered non-tappable.
- Missing target/source entity for a relation → that row is skipped.
- No description / no relations / no entries → respective sections omitted; header always renders.
- Deep back stacks are bounded only by normal navigation; no special handling needed.

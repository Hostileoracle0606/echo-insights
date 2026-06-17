# Lumen × GraphLoop — Read-Side Memory (Phase 1) — Design Spec

**Date:** 2026-06-17
**Status:** Approved (design), pending implementation plan
**Author:** brainstormed with Claude
**Scope:** echo-insights (TanStack Start web app). The Flutter iOS port is out of scope for this spec — GraphLoop is a TS/JS library.

---

## 1. Context & Motivation

Lumen is a voice journaling app that silently builds a knowledge graph as the user speaks. Today the
graph layer is entirely **write-side**:

- `extractGraph(body, signal, mode)` ([src/lib/extract-graph.ts:714](../../../src/lib/extract-graph.ts)) calls
  Gemini 2.5 Flash and returns an `ExtractGraphResult` (entities, relations, supersedes, follow-up).
- `mergeExtraction(prev, text, payload)` ([src/lib/journal-store.ts:291](../../../src/lib/journal-store.ts)) is a
  pure reducer merging the payload into `JournalState`.
- `buildGraphSummary()` ([src/routes/index.tsx:611](../../../src/routes/index.tsx)) projects an *agenda*
  (thin / probed / justMentioned / bridgeCandidates / uncertainRelations) for the voice agent's private
  `get_graph_summary` tool.

There is no **read-side**: given a query, nothing pulls the relevant subgraph back out. The agent can be
told *what the graph doesn't know* (agenda) but cannot recall *what past memory is relevant to the current
moment*.

[GraphLoop](https://github.com/Hostileoracle0606/graphloop) — which originated from this project — has since
grown a read-side: `engine.retrieve(query)` returning a ranked, provenance-backed subgraph plus a packed,
LLM-ready `context` string, with **no LLM calls during retrieval** (BM25 lexical always on, optional hybrid
vectors, Louvain community fallback). This spec integrates that read-side into Lumen.

### Why additive, not a rewrite
Lumen and GraphLoop share a common ancestor, so their write-side (extract → merge → agenda) is largely
duplicated. GraphLoop's genuinely new value is the **read-side**. Lumen's write path is latency-sensitive
and product-specific (sentence-boundary extraction, abort/supersede, wiki/granular modes, Gemini Live
coordination, Supabase notebooks, contradiction handling, Flutter parity). Replacing it would create a
second source of truth or force a risky migration. So Phase 1 adds retrieval **beside** the untouched write
path; consolidating the write-side onto `LiveGraphEngine` is deferred to its own later spec (§12).

---

## 2. Goals / Non-Goals

### Goals
- Add a read-side `retrieveMemory(state, query, opts?)` returning a ranked subgraph + provenance + a packed
  `context` string. **No LLM calls during retrieval.**
- Expose it to the voice agent through a **separate** private tool `get_relevant_memory({ query })`, distinct
  from `get_graph_summary` (agenda = "what to ask next"; retrieval = "what's relevant now").
- Fix **durable provenance** so grounded source passages survive a Supabase reload (prerequisite).
- Reuse GraphLoop's retrieval modules by **vendoring** them verbatim into `src/lib/graphloop/`, with one
  hand-written Lumen adapter as the only glue.
- Lexical (BM25) + Louvain community fallback, both deterministic and browser-safe; hybrid vector embeddings
  vendored but dormant.
- Match Lumen's existing patterns: pure functions, fail-closed error handling, snapshot-replace persistence,
  deterministic unit tests.

### Non-Goals (deferred)
- **Hybrid vector retrieval** (embeddings). Vendored (`embed.ts`) but not wired; `embeddingModel` left unset
  so the lexical path is the only active path. Add once the read path proves useful (cost/latency/privacy
  decisions belong to that step).
- **Cross-notebook (long-term) memory.** Phase 1 retrieves over the **active notebook only** — the
  `JournalState` already held in memory. A per-user aggregate across all notebooks (with cross-notebook
  entity reconciliation by slug) is a later phase.
- **Write-side swap** onto `LiveGraphEngine` (§12).
- Reranker, LanceDB scale backend, LLM-generated community labels.

---

## 3. Decisions (with rationale)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Additive read-side**; write path untouched | Retrieval is the new value; the write path is fragile and product-specific. Avoids a second source of truth. |
| D2 | **Vendor** GraphLoop's retrieval modules into `src/lib/graphloop/` | npm name `graphloop` is taken by an unrelated package (v5.1.2). Vendoring = zero install friction, fully in-repo, easiest to debug. Verbatim copies keep upstream re-sync trivial. |
| D3 | **Active-notebook scope** for Phase 1 | Retrieve over the in-memory `JournalState`; zero extra fetch; matches today's single-notebook model. Cross-notebook deferred. |
| D4 | **Separate `get_relevant_memory` tool** | Agenda and retrieval answer different questions; separate tools are easier to test, tune, and reason about. |
| D5 | **Lexical BM25 first**, hybrid vectors deferred | Cheaper, explainable, deterministic, no embedding cost / cache invalidation / provider / privacy questions. Vectors must beat the lexical baseline before becoming default. |
| D6 | **Include Louvain community fallback** in Phase 1 | Pure/deterministic (no embeddings), trivially fast at single-notebook sizes; turns broad queries into a useful "areas of memory" answer instead of empty. |
| D7 | **Durable provenance is a prerequisite** | `retrieve()` grounds results via `entry.entityIds/relationIds`; these are lost on Supabase reload today (§5.2). Fix ships before/with retrieval. |
| D8 | **Client-side retrieval** | Orama + graphology are browser-safe; lexical path is pure. Runs in the live-session route with no server round-trip and no LLM call. |

---

## 4. Architecture

A read-side memory layer sits beside the untouched write path.

```
user speaks ─► (UNCHANGED) extractGraph ─► mergeExtraction ─► state ─► saveState (now w/ provenance)
agent turn  ─► get_relevant_memory({ query })
                 └─► retrieveMemory(state, query)                       [src/lib/journal-memory.ts]
                       toGraphState(state)            ── pick entities/relations/entries
                       SearchIndex.sync(entities)     ── lazy, hash-keyed (Orama)
                       buildCommunities(graphState)   ── Louvain (global fallback)
                       retrieve(graphState, query, opts, { index, communities })
                       → { context, entities, relations, entries, seeds, communities? }
                 └─► return { context } ── injected as grounding for the agent's reply
```

### Module dependency direction (vendored)
```
journal-memory.ts ─► graphloop/retrieve.ts ─► graphloop/graph-ops.ts   (pure)
                                          ├─► graphloop/search-index.ts ─► @orama/orama
                                          ├─► graphloop/communities.ts  ─► graphology (+louvain)
                                          ├─► graphloop/embed.ts        ─► ai (embedMany)  [dormant]
                                          └─► graphloop/noise.ts        (normalizeName)
```
The lexical path is deterministic; network/LLM only enters through `embed.ts`, which is not invoked in
Phase 1 (no `embeddingModel` configured).

---

## 5. File Layout & Data Model

### 5.1 Vendored modules — `src/lib/graphloop/` (verbatim copies)

| File | Responsibility | Dep |
|---|---|---|
| `types.ts` | Trimmed to retrieval types: `GraphState`, `Entity`, `Relation`, `GraphEntry`, `EntityType`, `RankWeights`, `RetrievalOptions`, `RetrievalResult`, `CommunitySummary`, `DEFAULT_RANK_WEIGHTS`. Omits engine/extractor/storage types. | — |
| `noise.ts` | `normalizeName` (+ `filterNoise`, `DEFAULT_NOISE_NAMES`); only `normalizeName` is used by retrieve. | — |
| `graph-ops.ts` | `activeRelations`, `buildNeighbors`, `relationUncertainty`, `wordCount`. Pure, zero deps. | — |
| `search-index.ts` | `SearchIndex` — Orama wrapper. BM25 over `name + description`; optional vector field; lazy hash-keyed sync (`lastSeen|name|description|v?n`). | `@orama/orama` |
| `communities.ts` | `buildCommunities(state)` — graphology + Louvain over active relations → `CommunitySummary[]` (top entities by degree/mentions). | `graphology`, `graphology-communities-louvain` |
| `embed.ts` | `embedTexts(model, texts)` via AI SDK `embedMany`. **Dormant in Phase 1.** | `ai` (present) |
| `retrieve.ts` | `retrieve(state, query, opts, deps)` — seed → expand → provenance → rank → budget → pack. Verbatim. | — |
| `index.ts` | Barrel re-exporting the above. | — |

Vendored files are **pure copies** so upstream changes re-sync by re-copying. The only permitted edit is
trimming unused exports from `types.ts`.

> **Structural compatibility (verified):** GraphLoop's `Entity`, `Relation`, and `GraphEntry` are
> field-for-field identical to Lumen's `Entity`, `Relation`, and `JournalEntry`
> ([src/lib/journal-types.ts](../../../src/lib/journal-types.ts)). GraphLoop `GraphState` =
> `{ entities, relations, entries }`; Lumen `JournalState` = the same plus `followUps`, `askedQuestions`.
> TypeScript structural typing therefore accepts Lumen objects wherever GraphLoop types are expected, so the
> adapter is a field pick, not a deep transform.

### 5.2 Hand-written adapter — `src/lib/journal-memory.ts` (NEW)

The only glue. Responsibilities:
- `toGraphState(state: JournalState): GraphState` → `{ entities: state.entities, relations: state.relations, entries: state.entries }`.
- Own a per-notebook `SearchIndex` instance (module-level, keyed by notebook id; recreated on notebook
  switch or `clearState`).
- `retrieveMemory(state, query, opts?)`:
  1. `const g = toGraphState(state)`
  2. `await index.sync(Object.values(g.entities))` — lazy, hash-keyed; no embeddings in Phase 1.
  3. `const communities = buildCommunities(g)`
  4. `return retrieve(g, query, { mode: "lexical", ...opts }, { index, communities })`
- Fail-closed: on any thrown error, log and return an empty `RetrievalResult` (`{ entities:[], relations:[],
  entries:[], seeds:[], context:"" }`).

### 5.3 Durable provenance — Supabase schema change (prerequisite)

`retrieve()` attaches grounding via:
```ts
state.entries.filter(en => en.entityIds.some(id => keptIds.has(id))
                        || en.relationIds.some(id => relIds.has(id)))
```
Today `saveState` writes journal entries as `{ id, user_id, notebook_id, text, created_at }` only, and
`rowToEntry` reconstructs them with `entityIds: [], relationIds: []`
([src/lib/journal-store.ts:471](../../../src/lib/journal-store.ts)). So after a reload the provenance links
are empty and retrieval returns nodes with **no `## Sources` passages**. In-session (pre-reload) it works
because `mergeExtraction` populates the arrays in memory; reload loses them.

**Fix** (mirrors the existing `follow_ups.target_entity_ids text[]` pattern):
```sql
-- supabase/migrations/<ts>_journal_entries_provenance.sql
alter table journal_entries
  add column entity_ids   text[] not null default '{}',
  add column relation_ids text[] not null default '{}';
```
- `saveState`: insert `entity_ids: e.entityIds, relation_ids: e.relationIds`.
- `rowToEntry`: read `entityIds: r.entity_ids ?? [], relationIds: r.relation_ids ?? []`.

Snapshot-replace save means **no backfill** is needed: existing rows default to empty arrays and gain real
provenance the next time their notebook is saved. This is a correctness fix for grounding independent of
retrieval, and also serves as an audit trail (helps explain and delete memory correctly).

### 5.4 New dependencies (`package.json`)
- `@orama/orama` (^3.1) — search substrate, pure TS, browser-safe.
- `graphology` (^0.26) + `graphology-communities-louvain` (^2.0) — community fallback.
- `ai` (^6) already present; used only when hybrid lands.

---

## 6. Retrieval Pipeline (reference — vendored `retrieve.ts`)

Lexical local tier (the active Phase 1 path):

1. **Seed selection** — `SearchIndex.search(query, undefined, maxEntities*2)` (BM25 over `name +
   description`). Exact normalized-name matches are always included so precise names are never lost to
   ranking. Seed scores normalized to `[0,1]`.
2. **Expansion** — BFS to `hops` (default 2) over **active** relations only, recording hop distance per node.
3. **Provenance + ranking** (pure), per entity:
   - `relevance = (hop 0 ? seedScore : 0.5) * 0.6^hop`
   - `recency = exp(-ageDays/30)` on `lastSeen`
   - `importance = log(mentions+1) / log(maxMentions+1)`
   - `confidence = mean(1 - uncertainty(rel)/3)` over incident relations, else `min(1, descWords/30)`
   - `total = Σ weight_i · signal_i` with `DEFAULT_RANK_WEIGHTS = { relevance:1.0, recency:0.3, importance:0.4, confidence:0.3 }`
4. **Budget** — keep top `maxEntities` (24); keep relations whose **both** endpoints survive (connectivity
   invariant), capped at `maxRelations` (48).
5. **Pack** — compact `context` string: `## Entities` / `## Relations` / `## Sources` (≤12 verbatim
   entries), plus the structured `entities/relations/entries` for programmatic use.

**Global fallback** — when there are **zero** lexical seeds (or `tier:"global"`), pack the top community
summaries instead: `## Relevant areas of memory\n- {label} ({size} entities): {topEntities}`. Communities are
computed in the adapter and passed via `deps.communities`.

---

## 7. Agent Integration

Register a second private tool with Gemini Live alongside `get_graph_summary`
([src/routes/index.tsx:769](../../../src/routes/index.tsx)):

```ts
{ name: "get_relevant_memory",
  description: "Retrieve past memory relevant to a query.",
  parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } }
```
Handler:
```ts
if (call.name === "get_relevant_memory") {
  const { context } = await retrieveMemory(stateRef.current, call.args.query ?? "");
  return { context };
}
```

`conversation-policy.ts` gains a paragraph mirroring the existing `get_graph_summary` privacy framing
([src/lib/conversation-policy.ts:291](../../../src/lib/conversation-policy.ts)):

> **YOUR SECOND PRIVATE TOOL — `get_relevant_memory({ query })`:** Where `get_graph_summary` tells you what
> to ask next, this returns past memory relevant to *right now*. Call it when the user references something
> from earlier or the past, or when grounding your reply in prior context would help. The result is for your
> planning only — never read it aloud and never mention the graph, memory, or these fields.

---

## 8. Error Handling & Honesty Rules

- **Empty/whitespace query** → empty `RetrievalResult`.
- **No lexical seeds** → community fallback; if still nothing → honest empty ("no relevant memory").
  **Never** dump the whole graph.
- **Index / Orama / graphology failure** → caught in `retrieveMemory`; log via existing channel; return
  empty result so a recall failure never breaks the live turn.
- **Superseded relations excluded** everywhere (`activeRelations` filters `supersededAt`), so contradicted
  facts cannot leak back in.
- Retrieval performs **no LLM calls** in Phase 1 (embeddings dormant).

---

## 9. Testing Strategy

Follows existing patterns (pure-function fixtures; deterministic).

- **Ported from GraphLoop** (adapted to vendored paths): `graph-ops` (k-hop boundary, active-only,
  neighbor/uncertainty parity), `search-index` (BM25 ranking, exact-name inclusion, hash-keyed incremental
  sync), `communities` (Louvain partition, summary = top entities), `retrieve` (local-only, global fallback
  on broad query, empty-on-no-match, no-LLM-call assertion, budget connectivity invariant).
- **Lumen-specific (new):**
  - **Provenance round-trip** — `saveState` → `loadState` preserves `entityIds/relationIds` (mock Supabase
    or assert the row mapping in `rowToEntry`/`saveState`).
  - **`retrieveMemory` integration** — over a `JournalState` fixture: correct seeds, k-hop expansion,
    grounded `## Sources`, honest-empty on no match, fail-closed on a thrown index error.

---

## 10. Dependencies & Compatibility

- Browser/SSR: vendored modules must be imported only on the **client** (the live-session route). Lumen's
  `src/routes/index.tsx` is already a client component (uses `window`, `localStorage`). Orama and graphology
  are browser-safe. No edge function needed for the lexical path.
- No change to the existing extractor, merge reducer, agenda, or Supabase save strategy beyond the two new
  `journal_entries` columns.

---

## 11. Implementation Phases

Each phase ends green (tests pass, app builds) before the next.

1. **Provenance fix** — migration + `saveState`/`rowToEntry`; round-trip test. *(Prerequisite; independently
   valuable.)*
2. **Vendor modules** — copy `types.ts` (trimmed), `noise.ts`, `graph-ops.ts`, `search-index.ts`,
   `communities.ts`, `embed.ts`, `retrieve.ts`, `index.ts`; add deps; port their tests.
3. **Adapter** — `journal-memory.ts`: `toGraphState`, per-notebook `SearchIndex`, `retrieveMemory`,
   fail-closed; integration test.
4. **Agent tool** — register `get_relevant_memory`, wire handler, update `conversation-policy.ts`.
5. **Verify** — build, run the app, confirm a recall query returns grounded context during a live session.

---

## 12. Open Questions / Future (deferred, each its own spec)

- **Hybrid vectors.** Wire `embed.ts` + `embeddingModel`; decide provider, embedding cost, cache
  invalidation, and the client/server boundary (embeddings need a network call). Must beat the lexical
  baseline before becoming default.
- **Cross-notebook long-term memory.** Build a per-user aggregate `GraphState` across notebooks and reconcile
  entities sharing a slug (merge mentions/descriptions/lastSeen). Enables "remember weeks ago…".
- **Write-side consolidation.** Replace `extractGraph` + `mergeExtraction` + `buildGraphSummary` with
  `LiveGraphEngine`, layering Lumen's `followUps`/`askedQuestions` as a sidecar (GraphLoop has no such
  concept) and a Supabase `StorageAdapter`. Removes the duplicated write-side; higher risk — gated on
  retrieval proving out first.
- **Community caching.** `buildCommunities` runs per `retrieve()` call; cache by an active-relation signature
  when graphs grow.
- **Index `GraphEntry.text`** as searchable docs for sentence-level recall (currently entities only).

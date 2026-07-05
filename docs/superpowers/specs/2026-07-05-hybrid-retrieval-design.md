# Phase 2a — Hybrid (Semantic) Retrieval — Design Spec

**Date:** 2026-07-05
**Status:** Approved (design), pending implementation plan
**Author:** brainstormed with Claude
**Scope:** echo-insights retrieval layer — the `retrieve-memory` Supabase edge function, shared `graphloop`, and a new write-time embedding path. Benefits **both** the Flutter app and the web app (shared graphloop change).

**Builds on:** [2026-06-25-flutter-graph-rag-retrieve-design.md](2026-06-25-flutter-graph-rag-retrieve-design.md) (Phase 1, deployed + verified). This is the first Phase 2 slice (§10 of that spec).

---

## 1. Context & Motivation

Phase 1 shipped lexical retrieval: BM25 (Orama) + exact-name match → k-hop expansion → multi-signal ranking → source-free context. It is deployed on the live project (`bjoevzvsdlhlcjywpyfx`) and passes a 7-scenario eval (macro-F1 95%).

Its one blind spot is **semantic recall**: a query with no keyword overlap with an entity's name/description misses. "the thing about my startup" won't surface `Project Atlas` unless the word "startup" literally appears. Hybrid retrieval adds vector similarity alongside BM25 so meaning-based matches are found.

### The measurement that shaped this design

We considered embedding entities on-demand inside the edge function (zero schema). A latency probe against the **real** Supabase edge runtime (native `gte-small`) settled it:

| Entities embedded per call | Result |
|---|---|
| 1 | 118 ms |
| 10 | 1,189 ms (~119 ms each, linear, CPU-bound, no batching) |
| 25 | **`WORKER_RESOURCE_LIMIT` (HTTP 546) at ~2.2 s** |

**Conclusion:** re-embedding the graph per call is non-viable — it adds seconds and *crashes* past ~20 entities (edge worker CPU cap). Embedding the **query alone** (1×) is fine. This forces the standard **embed-once-search-many** design: entities embedded once at write time and persisted; only the query embedded at read time.

### Why not a framework (LangChain / Graphiti / Mem0)

Same conclusion as Phase 1's OSS review, one level down: **reuse primitives, not frameworks.** Our need is a single pgvector similarity query + a native embedding call — both one-liners in our stack. A framework would duplicate graphloop, add Deno cold-start weight against a runtime with a hard CPU limit, fork retrieval from the shared web graphloop, and weaken control over the privacy-critical source-free path. Reused primitives: **pgvector** (native), **native `gte-small`** in edge functions, **graphloop** ranking (shared).

---

## 2. Goals / Non-Goals

### Goals

- Add semantic seeds to retrieval so meaning-based matches surface, **merged into** graphloop's existing lexical + k-hop + ranking pipeline (not replacing it).
- Embed entities **once at write time**, persisted in pgvector; embed only the **query** at read time.
- **Shared across Flutter and web:** the graphloop change is applied to both copies; the write-time embedding fires on any entity write regardless of client.
- Preserve every Phase 1 invariant: source-free egress, auth/ownership/rate-limit, fail-closed, state-in-body freshness for graph structure.
- Keep it locally testable despite native `gte-small` being edge-runtime-only (pluggable `Embedder`).

### Non-Goals

- **No re-embedding at read time** (the probe rules it out).
- **No cross-notebook / cross-day recall** (that is a separate Phase 2 slice).
- **No external embedding API** — native `gte-small` keeps text on-platform (privacy).
- **No reranker / RRF framework** — semantic seeds feed graphloop's existing ranker.
- **No change to the source-free output contract.**

---

## 3. Design Decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Vector source | **Persisted (pgvector)**, embed-once | Read-time embedding crashes at ~25 entities (measured) |
| Read-time embedding | **Query only** (1× ~119 ms) | Cheap and bounded |
| Embedding model | **Native `gte-small`** (384-dim) in edge functions | On-platform (privacy), zero external dep |
| Similarity search | **pgvector** SQL, HNSW cosine, scoped to notebook | We persist there anyway; indexed + fast |
| Seed merge | **Extend `retrieve()` with optional `extraSeeds`** | Semantic seeds join graphloop's lexical seeds; ranker unchanged |
| Code sharing (Decision A) | **Shared graphloop** — change both `src/lib/graphloop` + vendored copy | Drift-guard green; web app gets hybrid too |
| Write trigger (Decision B) | **Postgres trigger + `pg_net`** on entity insert/update | Write-agnostic — serves Flutter *and* web with no per-client wiring |
| Freshness fallback | New entity without a vector yet → **lexical/exact-name seeding only** | Phase 1's strength; semantic seed appears once embedded (async) |

---

## 4. Architecture & Data Flow

```
WRITE TIME (async, any client)               READ TIME (per recall call)
──────────────────────────────              ───────────────────────────────
entity insert/update (Flutter OR web)        retrieve-memory (edge fn):
   │                                            embed QUERY  (gte-small, 1× ~119ms)
   ├─ Postgres trigger → pg_net POST ──►          │
   │     embed-entities edge fn:                 pgvector cosine search WITHIN notebook
   │       embed CHANGED entities (chunks ≤10)     (HNSW, top-K, threshold) → seed ids+scores
   │       write vectors ──► entity_embeddings    │
   │                          (pgvector)         merge extraSeeds into graphloop retrieve()
   │                                              → lexical seeds ∪ semantic seeds
   └─ (one-time backfill for existing rows)       → k-hop + rank + source-free pack (unchanged)
```

The request body still carries the full graph (structure, ranking inputs, freshness). pgvector supplies only **semantic seed entity-ids**; the ids stitch the persisted vectors to the in-body graph.

---

## 5. Components

### 5.1 Schema — `entity_embeddings` (new migration)

```sql
create extension if not exists vector;

create table public.entity_embeddings (
  notebook_id  uuid not null references public.notebooks(id) on delete cascade,
  entity_id    text not null,
  user_id      uuid not null references auth.users(id) on delete cascade,
  embedding    vector(384) not null,
  content_hash text not null,          -- hash of name+description; skip re-embed when unchanged
  updated_at   timestamptz not null default now(),
  primary key (notebook_id, entity_id)
);

alter table public.entity_embeddings enable row level security;
create policy "owner select" on public.entity_embeddings for select using (auth.uid() = user_id);
create policy "owner all"    on public.entity_embeddings for all    using (auth.uid() = user_id) with check (auth.uid() = user_id);

create index entity_embeddings_hnsw
  on public.entity_embeddings using hnsw (embedding vector_cosine_ops);
create index entity_embeddings_notebook on public.entity_embeddings (notebook_id);
```

`(notebook_id, entity_id)` PK mirrors the `entities` table PK. `content_hash` avoids redundant re-embedding. HNSW cosine index for fast approximate search; a per-notebook btree bounds the search set.

### 5.2 Write-time embedder — `embed-entities` edge function + trigger

- **New edge function `supabase/functions/embed-entities`**: input = `{ notebookId, entityIds? }`. Loads the named entities (or all stale/missing-vector entities in the notebook), computes `content_hash`, and for those whose hash changed or is missing: embeds `name + "\n" + (description ?? "")` via native `gte-small` **in chunks ≤ 10** (staying under the measured ~2 s CPU limit; loop chunks across invocations if needed), upserts into `entity_embeddings`. Auth via the same JWT/service pattern; RLS-scoped.
- **Trigger (Decision B):** a Postgres `after insert or update` trigger on `public.entities` calls `pg_net` (`net.http_post`) to invoke `embed-entities` for the changed `notebook_id` (debounced/coalesced to avoid a storm on bulk `saveState`). `pg_net` extension enabled in the migration.
- **Backfill:** a one-time chunked job (script or an `embed-entities` mode) embeds all existing entities lacking a vector.
- **Failure handling:** embedding is best-effort and async — a failed/late embedding never blocks a write or a read; the entity simply falls back to lexical seeding until its vector lands. Trigger failures are logged (non-sensitive), not fatal.

### 5.3 Read-time semantic seeding — `retrieve-memory` changes

After auth/ownership/rate-limit and before graphloop retrieval:
1. Embed the query via `gte-small` (1×).
2. pgvector cosine search `where notebook_id = $nb order by embedding <=> $q limit K` (K≈12), keep hits above a cosine-similarity threshold (default 0.7).
3. Build `extraSeeds: Map<entityId, score>` from the hits (normalized similarity).
4. Pass `extraSeeds` into `retrieve()`; graphloop merges them with its lexical/exact-name seeds and runs k-hop + ranking + source-free packing unchanged.

If the query embedding or pgvector search fails → omit `extraSeeds` (retrieval degrades to Phase 1 lexical, never errors).

### 5.4 graphloop `retrieve()` — `extraSeeds` (shared change, both copies)

Extend `RetrievalOptions`/`retrieve()` with an optional `extraSeeds?: Map<string, number>` (entity-id → seed relevance in [0,1]). In the seed-selection step, union these with the existing BM25 + exact-name seeds (take the max score per id). Everything downstream (k-hop, ranking, budget, packing) is unchanged. Applied to **both** `src/lib/graphloop/retrieve.ts` and the vendored `supabase/functions/_shared/graphloop/retrieve.ts`; the sync script + drift guard keep them identical. The web app can adopt hybrid later by supplying `extraSeeds`; passing nothing preserves exact Phase 1 behavior (backward compatible).

### 5.5 `Embedder` interface (pluggable, for testability)

A thin interface `Embedder { embed(texts: string[]): Promise<number[][]> }`:
- **Prod impl:** native `gte-small` (`Supabase.ai.Session`) — used by `embed-entities` and `retrieve-memory`.
- **Local/test impl:** a deterministic stub (e.g., hashed bag-of-words → fixed-dim vector) so the eval harness and unit tests run under local `deno` where `Supabase.ai` is absent.

---

## 6. Privacy

- Embeddings derive from entity `name`/`description` — already stored, owner-RLS. No new content is exposed.
- **Native `gte-small` keeps text on-platform** — no external embedding API sees journal content; this *strengthens* the no-egress stance.
- `entity_embeddings` is owner-RLS; vectors are not returned to clients.
- The retrieval **output contract is unchanged**: still entities + relations only, no source text. Hybrid changes *which entities seed*, never *what egresses*.

---

## 7. Latency budget (read path)

Measured `gte-small` = ~119 ms per embedding. Read path adds: 1 query embedding (~119 ms) + one indexed pgvector query (~single-digit ms). So hybrid adds **~120–150 ms** to a recall call (which was ~1.2 s in Phase 1, auth/DB-bound). Acceptable for a background tool call. Write-path embedding is async and off the user's turn.

---

## 8. Testing

- **Semantic-only eval scenario (new):** query "startup" → entity `Project Atlas` (description mentions a startup, **zero keyword overlap**) must be seeded via the vector path — the thing lexical cannot do. Added to the existing harness (`eval.ts`), using the local `Embedder` stub + precomputed vectors.
- **pgvector seeding unit test:** given fixture vectors, assert the correct top-K entity-ids come back above threshold.
- **No lexical regression:** re-run the existing 7 scenarios (they pass `extraSeeds = none`) — must stay 7/7.
- **`extraSeeds` merge test:** semantic seeds union correctly with lexical seeds (max score per id), k-hop still expands from the merged set.
- **Drift guard:** `check-graphloop-sync.mjs` stays green after the shared `retrieve.ts` change (re-sync the vendored copy).
- **Deployed parity + privacy:** re-run the live smoke (valid call, source-free output) after deploy.
- **Write-path:** insert/update an entity → assert a vector row appears (integration, live DB).

---

## 9. Risks & Known Limitations

- **Freshness lag for brand-new entities.** An entity has no vector until the async embed lands (~seconds), so semantic recall of a *just-created* entity lags by one embed cycle; lexical/exact-name seeding covers it meanwhile. Acceptable — new entities are usually named explicitly.
- **CPU limit (measured).** `embed-entities` must chunk ≤10 per invocation; a bulk backfill/`saveState` of many entities is spread across invocations. The trigger must coalesce to avoid an invocation storm.
- **HNSW is approximate.** Recall < 100% by construction; fine for seeding (graphloop's k-hop + exact-name backstop compensate). Tune `ef_search` if needed.
- **`pg_net` reliability.** Fire-and-forget HTTP from Postgres can drop; embedding is best-effort with a periodic reconcile (embed any entity missing a current-hash vector). Non-fatal by design.
- **Embedding drift vs graphloop scoring.** Semantic seeds enter as seed *relevance*; the composite ranker (recency/importance/confidence) still governs final order — so a weak semantic match can't dominate. Threshold + weight are tunable.

---

## 10. Prerequisites

- pgvector extension available on the project (native to Supabase — enable in the migration).
- `pg_net` extension for the trigger→function call (enable in the migration).
- Phase 1 deployed (done) and the `saveState` `user_id` fix (done) so entities persist for the trigger to fire on.

---

## 11. Implementation Gate

Do not ship until: `entity_embeddings` migration + HNSW index applied; `embed-entities` deployed and chunked ≤10; trigger + `pg_net` firing (coalesced); `retrieve-memory` semantic seeding wired with fail-closed fallback; `retrieve()` `extraSeeds` applied to **both** graphloop copies with drift guard green; `Embedder` stub for local tests; new semantic eval scenario passing + existing 7 still passing; deployed parity + source-free re-verified.

---

## 12. Sequential Build Steps

1. **Migration** — `vector` + `pg_net` extensions, `entity_embeddings` table, RLS, HNSW + notebook indexes.
2. **`Embedder` interface** + prod (`gte-small`) and local-stub impls; unit-test the stub determinism.
3. **`retrieve()` `extraSeeds`** — extend both graphloop copies, re-sync vendored, drift guard green; `extraSeeds` merge unit test; 7-scenario harness still 7/7.
4. **`embed-entities` edge fn** — chunked embedding + `content_hash` upsert; deploy; write-path integration test (entity → vector row).
5. **Trigger + `pg_net`** — coalesced `after insert/update` on `entities` → `embed-entities`; backfill existing entities.
6. **`retrieve-memory` semantic seeding** — query embed → pgvector search → `extraSeeds` → `retrieve()`, fail-closed; deploy.
7. **Eval + verify** — add the semantic-only scenario (local stub + fixture vectors); re-run harness; live deployed parity + source-free smoke.

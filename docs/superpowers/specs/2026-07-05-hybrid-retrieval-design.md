# Phase 2a — Hybrid (Semantic) Retrieval — Design Spec

**Date:** 2026-07-05
**Status:** Approved (design), hardened against spec review; pending implementation plan
**Author:** brainstormed with Claude
**Scope:** echo-insights retrieval layer — the `retrieve-memory` Supabase edge function, a new write-time embedding path, and a **shared** `graphloop` change. **This spec delivers hybrid on the Flutter/edge (`retrieve-memory`) path.** The graphloop change is applied to both copies so the web app *can* adopt hybrid later by wiring its own read path — but the web read path is a follow-up, not part of this spec.

**Builds on:** [2026-06-25-flutter-graph-rag-retrieve-design.md](2026-06-25-flutter-graph-rag-retrieve-design.md) (Phase 1, deployed + verified). First Phase 2 slice (§10 there).

---

## 1. Context & Motivation

Phase 1 shipped lexical retrieval: BM25 (Orama, over **name + description**) + exact-name match → k-hop → multi-signal ranking → source-free context. Deployed on `bjoevzvsdlhlcjywpyfx`, passes a 7-scenario eval (macro-F1 95%).

Blind spot: **semantic recall** with *no lexical overlap*. If the query shares no token with an entity's name **or description**, BM25 misses it (e.g., query "startup" vs description "venture-backed company"). Hybrid adds vector similarity so meaning-based matches surface.

### The measurement that shaped this design

A latency probe against the real edge runtime (native `gte-small`):

| Entities embedded per call | Result |
|---|---|
| 1 | 118 ms |
| 10 | 1,189 ms (~119 ms each, linear, CPU-bound) |
| 25 | **`WORKER_RESOURCE_LIMIT` (HTTP 546) at ~2.2 s** |

**Conclusion:** re-embedding the graph per call is non-viable (crashes past ~20 entities). Embedding the **query alone** (1×) is fine. Forces **embed-once-search-many**: entities embedded once at write time and persisted; only the query embedded at read.

### Why not a framework (LangChain / Graphiti / Mem0)

Reuse **primitives, not frameworks**: our need is one pgvector query + one native embedding call. A framework would duplicate graphloop, add Deno cold-start weight against a hard CPU limit, fork retrieval from the shared web graphloop, and weaken control over the privacy-critical path. Reused primitives: **pgvector**, native **`gte-small`**, **graphloop** ranking.

---

## 2. Goals / Non-Goals

### Goals

- Add semantic seeds to the **Flutter/edge** retrieval path, merged into graphloop's lexical + k-hop + ranking pipeline (not replacing it).
- Embed entities **once at write time** (persisted, pgvector); embed only the **query** at read.
- **Shared graphloop change** (`extraSeeds`) applied to both copies — backward compatible, drift-guard green — so the web app can adopt hybrid later.
- Preserve every Phase 1 invariant: source-free egress, auth/ownership/rate-limit, fail-closed, state-in-body freshness for structure.
- Locally testable despite native `gte-small` being edge-runtime-only (pluggable `Embedder`).

### Non-Goals

- **No re-embedding at read** (probe rules it out). **No external embedding API** (privacy).
- **No web read path in this spec** — graphloop is made hybrid-*capable*; wiring the web app's `retrieveMemory` to pgvector is a follow-up.
- **No cross-notebook recall**, **no reranker/RRF framework**, **no change to the source-free output contract.**

---

## 3. Design Decisions (resolved during brainstorming + review)

| Decision | Choice | Rationale |
|---|---|---|
| Vector source | **Persisted (pgvector)**, embed-once | Read-time embedding crashes at ~25 entities (measured) |
| Read-time embedding | **Query only** (1× ~119 ms) | Cheap, bounded |
| Model | **Native `gte-small`** (384-dim) | On-platform (privacy), zero external dep |
| Similarity search | **SECURITY DEFINER RPC over pgvector** (HNSW cosine), ownership-checked | Table stays locked; RPC returns ids+scores only |
| Seed merge | **`retrieve()` gains optional `extraSeeds`** | Semantic seeds join lexical seeds; ranker unchanged |
| Code sharing (Decision A) | **Shared graphloop** (both copies) | Drift-guard green; web-ready |
| Write trigger (Decision B) | **Trigger on `notebooks` update → `pg_net` → `embed-entities`**, once per save; reconcile | Saves are snapshot delete+insert; per-row triggers would storm |
| Write auth | **Internal secret + service-role** in `embed-entities` (no user JWT) | A DB trigger has no end-user JWT |
| Table access | **Locked** — RLS on, no client policy, grants revoked; access only via RPC/service-role | "Vectors never returned to clients" must be enforced, not asserted |

---

## 4. Architecture & Data Flow

```
WRITE TIME (async, any client, once per save)      READ TIME (per recall call)
────────────────────────────────────────────      ───────────────────────────────
saveState: delete+insert snapshot, then            retrieve-memory (edge fn, user JWT):
  UPDATE notebooks (entity_count, updated_at)         auth + ownership + rate-limit (Phase 1)
   │                                                   embed QUERY (gte-small, 1× ~119ms)
   └─ trigger AFTER UPDATE on notebooks                 │
        → pg_net POST (internal secret) ──►            rpc match_entity_embeddings(nb, qvec, k, thr)
             embed-entities (service-role):              (SECURITY DEFINER: ownership check +
               reconcile notebook:                        pgvector cosine search) → [{entity_id, score}]
                 hash each entity (name+desc)            │
                 embed changed/missing (chunks ≤10)     extraSeeds = {entity_id → score}
                 upsert entity_embeddings               │
                 PRUNE orphan vector rows               retrieve(state, q, {extraSeeds, mode:lexical})
   (+ pg_cron reconcile backstop)                        → lexical ∪ semantic seeds → k-hop → rank
                                                          → source-free pack (unchanged)
```

The request body still carries the full graph (structure, ranking, freshness). The RPC supplies only **semantic seed entity-ids + scores**; ids stitch persisted vectors to the in-body graph. Raw vectors never leave the DB.

---

## 5. Components

### 5.1 Schema — `entity_embeddings` (new migration) — locked, operational state

```sql
create extension if not exists vector;
create extension if not exists pg_net;

create table public.entity_embeddings (
  notebook_id  uuid not null references public.notebooks(id) on delete cascade,
  entity_id    text not null,
  user_id      uuid not null references auth.users(id) on delete cascade,
  embedding    vector(384) not null,
  content_hash text not null,
  updated_at   timestamptz not null default now(),
  primary key (notebook_id, entity_id)
);

-- Locked like retrieve_rate_limits: RLS on, NO client policy, grants revoked.
-- Only the SECURITY DEFINER RPC (read) and service-role (write) touch it.
alter table public.entity_embeddings enable row level security;
revoke all on table public.entity_embeddings from anon, authenticated;

create index entity_embeddings_hnsw
  on public.entity_embeddings using hnsw (embedding vector_cosine_ops);
create index entity_embeddings_notebook on public.entity_embeddings (notebook_id);
```

No client policy + revoked grants ⇒ a client **cannot** read or write embedding rows directly (enforces §6). `entity_embeddings` has **no FK to `entities`**, so it survives the snapshot delete+insert of `saveState`; the reconcile (§5.2) keeps it consistent. The `notebooks` FK cascade cleans it when a notebook is deleted.

### 5.2 Write-time embedder — trigger (once per save) + `embed-entities` + reconcile

**Saves are snapshot delete+insert** ([journal-store.ts:164](../../../src/lib/journal-store.ts), [supabase_service.dart:120](../../../lib/services/supabase_service.dart)) — deleting and reinserting *all* entities. So we do **not** trigger per entity row.

- **Trigger:** `after update on public.notebooks` (saveState bumps `notebooks.updated_at` once at the end of every save, on both apps) → `net.http_post` to `embed-entities` with `{ notebookId }` and an **internal secret header** (a Vault/DB-setting value). One call per save.
- **`embed-entities` edge function** (`verify_jwt = false`): validates the internal secret; uses the **service-role key** (RLS-bypassing) to reconcile the notebook — it has no end-user JWT and derives `user_id` from the entity rows themselves:
  1. Read all current `entities` for `notebookId`.
  2. For each, compute `content_hash = hash(name + "\n" + (description ?? ""))`. Embed (native `gte-small`) only those whose stored hash is missing or changed, **in chunks ≤ 10** (under the measured CPU limit; loop across invocations if the notebook is large). Upsert `(notebook_id, entity_id, user_id, embedding, content_hash)`.
  3. **Prune:** delete `entity_embeddings` rows whose `entity_id` is no longer among the notebook's current entities (orphans from snapshot deletes / removed entities).
- **Backstop:** a `pg_cron` job periodically reconciles notebooks with any entity lacking a current-hash vector (covers dropped `pg_net` calls — fire-and-forget HTTP from Postgres is best-effort).
- **Non-blocking:** embedding never blocks a write or read; an un-embedded entity falls back to lexical seeding until its vector lands.

### 5.3 Read-time semantic seeding — `retrieve-memory` + `match_entity_embeddings` RPC

New **SECURITY DEFINER** RPC (fixed `search_path`, execute granted to `authenticated`), mirroring `bump_retrieve_rate`:

```sql
-- Returns the top-K nearest entity ids + cosine similarity for an owned
-- notebook. The caller (edge fn) applies the score threshold. Only ids+scores
-- leave the DB, never vectors.
create or replace function public.match_entity_embeddings(
  p_notebook_id uuid, p_query vector(384), p_limit int
) returns table (entity_id text, score float)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.notebooks
                 where id = p_notebook_id and user_id = auth.uid()) then
    return;  -- not owner → empty
  end if;
  return query
    select e.entity_id, 1 - (e.embedding <=> p_query) as score
    from public.entity_embeddings e
    where e.notebook_id = p_notebook_id
    order by e.embedding <=> p_query
    limit p_limit;
end $$;
revoke all on function public.match_entity_embeddings(uuid, vector, int) from public, anon;
grant execute on function public.match_entity_embeddings(uuid, vector, int) to authenticated;
```

`retrieve-memory`, after Phase 1 auth/ownership/rate-limit and before graphloop:
1. Embed the query via `gte-small` (1×).
2. Call `match_entity_embeddings(notebookId, queryVec, K=12)`; keep hits with `score ≥ 0.7` (tunable).
3. Build `extraSeeds: Map<entityId, score>` from survivors.
4. Pass to `retrieve()`. On any failure (embed or RPC) → omit `extraSeeds` → Phase 1 lexical behavior (fail-closed, never errors).

The RPC verifies ownership internally (defense in depth beyond the edge function's own 404 check) and returns **only entity-ids + scores** — raw vectors never egress.

### 5.4 graphloop `retrieve()` — `extraSeeds` (shared change, both copies)

Add optional `extraSeeds?: Map<string, number>` (entity-id → seed relevance in [0,1]). In seed selection, union with the existing BM25 + exact-name seeds (max score per id). Downstream (k-hop, ranking, budget, packing) unchanged. Applied to **both** `src/lib/graphloop/retrieve.ts` and vendored `supabase/functions/_shared/graphloop/retrieve.ts`; sync script + drift guard keep them identical. Passing no `extraSeeds` = exact Phase 1 behavior (backward compatible). The web app becomes hybrid-*capable* here; wiring its `retrieveMemory` ([journal-memory.ts:62](../../../src/lib/journal-memory.ts), currently local lexical) to the RPC is a follow-up.

### 5.5 `Embedder` interface (pluggable, for testability)

`Embedder { embed(texts: string[]): Promise<number[][]> }`:
- **Prod:** native `gte-small` (`Supabase.ai.Session`), used by `embed-entities` + `retrieve-memory`.
- **Local/test:** deterministic stub (hashed token features → fixed 384-dim vector) so the eval harness + unit tests run under local `deno` (no `Supabase.ai`).

---

## 6. Privacy

- Embeddings derive from entity `name`/`description` — already stored. **Native `gte-small` keeps text on-platform** (no external embedding API), reinforcing no-egress.
- `entity_embeddings` is **locked** (§5.1): no client read/write; writes via service-role, reads via the ownership-checked RPC that returns ids+scores only. Raw vectors never leave the DB — so "vectors are not returned to clients" is **enforced**, not asserted.
- Retrieval **output contract unchanged**: entities + relations only, no source text. Hybrid changes which entities *seed*, never what *egresses*.

---

## 7. Latency budget (read path)

Measured `gte-small` ≈ 119 ms/embedding. Read path adds: 1 query embedding (~119 ms) + one HNSW-indexed RPC (~single-digit ms) ⇒ **~120–150 ms** on top of Phase 1's ~1.2 s (auth/DB-bound). Acceptable for a background tool call. Write-path embedding is async, off the user's turn.

---

## 8. Testing

- **Semantic-only eval scenario (new), zero lexical overlap:** query `"startup"`, entity name `"Northwind"` with description `"a venture-backed company"` — **no shared token** with the query, so BM25 (name+description) *cannot* match; only the vector path connects them. Assert it is seeded. (Uses the local `Embedder` stub + fixture vectors engineered so `startup`≈`venture-backed company`.) This is the case that fails without pgvector.
- **pgvector RPC test:** given fixture vectors, `match_entity_embeddings` returns the correct top-K ids above threshold and **empty** for a non-owner.
- **No lexical regression:** existing 7 scenarios (run with `extraSeeds = none`) stay 7/7.
- **`extraSeeds` merge test:** semantic ∪ lexical (max per id); k-hop expands from the merged set.
- **Drift guard:** `check-graphloop-sync.mjs` green after the shared `retrieve.ts` change (re-sync vendored).
- **Reconcile test (live DB):** save a notebook → vector rows appear for its entities; change an entity's description → its vector updates (hash changed); remove an entity → its vector row is pruned.
- **Deployed parity + source-free** re-verified after deploy.

---

## 9. Risks & Known Limitations

- **Freshness lag:** a just-created entity has no vector until the async reconcile lands (~seconds); lexical/exact-name seeding covers it meanwhile. New entities are usually named explicitly.
- **Snapshot churn:** saves delete+insert all entities; the `notebooks`-update trigger fires once per save and the reconcile (hash-diff embed + orphan prune) keeps `entity_embeddings` consistent without a per-row storm. `pg_cron` backstops dropped `pg_net` calls.
- **CPU limit (measured):** `embed-entities` chunks ≤10; large notebooks reconcile across invocations.
- **HNSW is approximate:** recall < 100% by construction; graphloop's k-hop + exact-name backstop compensate. Tune `ef_search` if needed.
- **Ranker dominance:** semantic seeds enter as seed *relevance*; the composite ranker (recency/importance/confidence) still governs final order, so a weak vector match can't dominate. Threshold + weight tunable.

---

## 10. Prerequisites

- `vector` + `pg_net` extensions (enabled in the migration); `pg_cron` for the backstop.
- An internal secret (Vault/DB setting) for the trigger→function call; `SUPABASE_SERVICE_ROLE_KEY` available to `embed-entities`.
- Phase 1 deployed (done) + `saveState` `user_id` fix (done) so entities persist and the trigger can reconcile.

---

## 11. Implementation Gate

Do not ship until: migration (`entity_embeddings` locked + HNSW, `match_entity_embeddings` RPC, extensions) applied; `embed-entities` deployed (internal-secret-gated, service-role, chunked ≤10, reconcile + prune); `notebooks` trigger + `pg_net` firing once per save; `pg_cron` backstop; `retrieve-memory` semantic seeding via RPC, fail-closed; `retrieve()` `extraSeeds` in **both** graphloop copies, drift guard green; `Embedder` stub; new zero-overlap semantic eval passing + existing 7 still passing; deployed parity + source-free re-verified.

---

## 12. Sequential Build Steps

1. **Migration** — `vector`/`pg_net` extensions; locked `entity_embeddings` (RLS on, no policy, revoked grants) + HNSW + notebook index; `match_entity_embeddings` SECURITY DEFINER RPC.
2. **`Embedder` interface** + prod (`gte-small`) + local stub; unit-test stub determinism.
3. **`retrieve()` `extraSeeds`** — both graphloop copies, re-sync vendored, drift guard green; merge unit test; 7-scenario harness still 7/7.
4. **`embed-entities` edge fn** — internal-secret check, service-role reconcile (hash-diff embed ≤10 + orphan prune); deploy; live reconcile test.
5. **Trigger + `pg_net` + `pg_cron`** — `after update on notebooks` → `embed-entities`; backfill existing entities; backstop job.
6. **`retrieve-memory` semantic seeding** — query embed → `match_entity_embeddings` RPC → `extraSeeds` → `retrieve()`, fail-closed; deploy.
7. **Eval + verify** — zero-overlap semantic scenario (local stub + fixture vectors); re-run harness; live deployed parity + source-free smoke.

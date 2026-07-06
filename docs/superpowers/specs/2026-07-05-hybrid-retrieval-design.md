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
| Similarity search | **Exact per-notebook scan** (notebook btree + exact cosine sort), via a **service-role-only** function called from the edge fn | Filtered HNSW silently misses notebook-local rows; per-notebook counts are small so exact = 100% recall + fast |
| Seed merge | **`retrieve()` gains optional `extraSeeds`** | Semantic seeds join lexical seeds; ranker unchanged |
| Code sharing (Decision A) | **Shared graphloop** (both copies) | Drift-guard green; web-ready |
| Write trigger (Decision B) | **Statement-level `after insert on entities`** (transition table → distinct notebook_ids) → `pg_net` → `embed-entities` | Saves are one bulk entity insert on both apps; fires once/save, client-agnostic (web `saveState` never bumps `notebooks`) |
| Write auth | **Internal secret + service-role** in `embed-entities` (no user JWT) | A DB trigger has no end-user JWT |
| Read access | **Service-role only** (function revoked from `authenticated`); `p_limit` clamped + server-fixed | A user-callable match RPC would bypass the edge fn's `bump_retrieve_rate`; keep it server-side, downstream of auth/ownership/rate |
| Table access | **Locked** — RLS on, no client policy, grants revoked; service-role writes, service-role reads | "Vectors never returned to clients" enforced, not asserted |

---

## 4. Architecture & Data Flow

```
WRITE TIME (async, any client, once per save)      READ TIME (per recall call)
────────────────────────────────────────────      ───────────────────────────────
saveState: ONE bulk `insert into entities`         retrieve-memory (edge fn):
  (both apps)                                         [user-JWT client] auth + ownership + rate-limit (Phase 1)
   │                                                  embed QUERY (gte-small, 1× ~119ms)
   └─ statement trigger AFTER INSERT on entities       │
        (transition table → distinct notebook_ids)    [service-role client] match_entity_embeddings(nb, qvec, 12)
        → pg_net POST (internal secret) ──►              exact per-notebook cosine scan → [{entity_id, score}]
             embed-entities (service-role):            │
               reconcile notebook:                     keep score ≥ 0.7 → extraSeeds = {entity_id → score}
                 hash each entity (name+desc)          │
                 embed changed/missing (chunks ≤10)    retrieve(state, q, {extraSeeds, mode:lexical})
                 upsert entity_embeddings               → lexical ∪ semantic seeds → k-hop → rank
                 PRUNE orphan vector rows               → source-free pack (unchanged)
   (+ pg_cron reconcile backstop)
```

The request body still carries the full graph (structure, ranking, freshness). The match supplies only **semantic seed entity-ids + scores**; ids stitch persisted vectors to the in-body graph. The match runs **server-side (service-role), downstream of the edge fn's auth/ownership/rate gates** — not user-callable. Raw vectors never leave the DB.

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
-- Only service-role (write) and the service-role-only match fn (read) touch it.
alter table public.entity_embeddings enable row level security;
revoke all on table public.entity_embeddings from anon, authenticated;

-- Per-notebook btree only. NO HNSW at this scale: filtering an approximate
-- HNSW index by a highly-selective notebook_id applies the filter AFTER the
-- index scan and can silently return too few rows. Per-notebook entity counts
-- are small (tens), so an exact scan over the notebook's rows is both 100%
-- recall and fast. (Scale-up path if a notebook grows large: add HNSW +
-- `SET LOCAL hnsw.iterative_scan`.)
create index entity_embeddings_notebook on public.entity_embeddings (notebook_id);
```

No client policy + revoked grants ⇒ a client **cannot** read or write embedding rows directly (enforces §6). `entity_embeddings` has **no FK to `entities`**, so it survives the snapshot delete+insert of `saveState`; the reconcile (§5.2) keeps it consistent. The `notebooks` FK cascade cleans it when a notebook is deleted.

### 5.2 Write-time embedder — trigger (once per save) + `embed-entities` + reconcile

**Saves are snapshot delete+insert** ([journal-store.ts:164](../../../src/lib/journal-store.ts), [supabase_service.dart:120](../../../lib/services/supabase_service.dart)) — deleting and reinserting *all* entities in **one bulk `insert` statement**. Web `saveState` never updates `notebooks` (unlike Flutter), so a notebooks-update trigger would miss web entirely. So we trigger on the entity insert itself, at **statement** level (not per row).

- **Trigger:** `after insert on public.entities referencing new table as new_rows for each statement` → the trigger fn selects `distinct notebook_id, user_id from new_rows` and, per notebook, `net.http_post`s to `embed-entities` with `{ notebookId }` and an **internal secret header** (a Vault/DB-setting value). Fires **once per bulk save** on both apps, regardless of entity count — no per-row storm, no dependency on client-side notebook bumps. (A `clearState`/delete that empties a notebook does not fire this insert trigger; its orphan vectors are pruned by the `pg_cron` backstop.)
- **`embed-entities` edge function** (`verify_jwt = false`): validates the internal secret; uses the **service-role key** (RLS-bypassing) to reconcile the notebook — it has no end-user JWT and derives `user_id` from the entity rows themselves:
  1. Read all current `entities` for `notebookId`.
  2. For each, compute `content_hash = hash(name + "\n" + (description ?? ""))`. Embed (native `gte-small`) only those whose stored hash is missing or changed, **in chunks ≤ 10** (under the measured CPU limit; loop across invocations if the notebook is large). Upsert `(notebook_id, entity_id, user_id, embedding, content_hash)`.
  3. **Prune:** delete `entity_embeddings` rows whose `entity_id` is no longer among the notebook's current entities (orphans from snapshot deletes / removed entities).
- **Backstop:** a `pg_cron` job periodically reconciles notebooks with any entity lacking a current-hash vector (covers dropped `pg_net` calls — fire-and-forget HTTP from Postgres is best-effort).
- **Non-blocking:** embedding never blocks a write or read; an un-embedded entity falls back to lexical seeding until its vector lands.

### 5.3 Read-time semantic seeding — `retrieve-memory` + service-role match fn

The match is **server-only** — a function granted **only to `service_role`** (revoked from `anon`/`authenticated`), so a user JWT cannot call it directly and thereby bypass the edge fn's `bump_retrieve_rate`. It does an **exact per-notebook scan** (not HNSW; §5.1) and **clamps `p_limit`**:

```sql
create or replace function public.match_entity_embeddings(
  p_notebook_id uuid, p_query vector(384), p_limit int
) returns table (entity_id text, score float)
language sql stable as $$
  select e.entity_id, 1 - (e.embedding <=> p_query) as score
  from public.entity_embeddings e
  where e.notebook_id = p_notebook_id
  order by e.embedding <=> p_query
  limit least(greatest(p_limit, 1), 50);   -- clamp caller-controlled limit
$$;
revoke all on function public.match_entity_embeddings(uuid, vector, int) from public, anon, authenticated;
grant execute on function public.match_entity_embeddings(uuid, vector, int) to service_role;
```

Ownership is **not** re-checked here — it's already enforced upstream by the edge fn (Phase 1's 404 ownership check + `bump_retrieve_rate`) before this runs; and the function is service-role-only so nothing else can reach it.

`retrieve-memory`, after Phase 1 auth/ownership/**rate-limit** (unchanged, on the user-JWT client) and before graphloop:
1. Embed the query via `gte-small` (1×).
2. Using a **service-role client**, call `match_entity_embeddings(notebookId, queryVec, 12)` — `K=12` is **server-fixed**, not client-supplied.
3. Keep hits with `score ≥ 0.7` (tunable) → build `extraSeeds: Map<entityId, score>`.
4. Pass to `retrieve()`. On any failure (embed or query) → omit `extraSeeds` → Phase 1 lexical behavior (fail-closed, never errors).

Only entity-ids + scores leave the DB — raw vectors never egress. The edge fn thus holds two clients: the user-JWT client (auth/ownership/rate, Phase 1) and a service-role client (the locked-table match).

### 5.4 graphloop `retrieve()` — `extraSeeds` (shared change, both copies)

Add optional `extraSeeds?: Map<string, number>` (entity-id → seed relevance in [0,1]). In seed selection, union with the existing BM25 + exact-name seeds (max score per id). Downstream (k-hop, ranking, budget, packing) unchanged. Applied to **both** `src/lib/graphloop/retrieve.ts` and vendored `supabase/functions/_shared/graphloop/retrieve.ts`; sync script + drift guard keep them identical. Passing no `extraSeeds` = exact Phase 1 behavior (backward compatible). The web app becomes hybrid-*capable* here; wiring its `retrieveMemory` ([journal-memory.ts:62](../../../src/lib/journal-memory.ts), currently local lexical) to the RPC is a follow-up.

### 5.5 `Embedder` interface (pluggable, for testability)

`Embedder { embed(texts: string[]): Promise<number[][]> }`:
- **Prod:** native `gte-small` (`Supabase.ai.Session`), used by `embed-entities` + `retrieve-memory`.
- **Local/test:** deterministic stub (hashed token features → fixed 384-dim vector) so the eval harness + unit tests run under local `deno` (no `Supabase.ai`).

---

## 6. Privacy

- Embeddings derive from entity `name`/`description` — already stored. **Native `gte-small` keeps text on-platform** (no external embedding API), reinforcing no-egress.
- `entity_embeddings` is **locked** (§5.1): no client read/write; writes via service-role, reads via a **service-role-only** match function (revoked from `authenticated`) called server-side inside the edge fn, returning ids+scores only. Raw vectors never leave the DB — so "vectors are not returned to clients" is **enforced**, not asserted.
- Retrieval **output contract unchanged**: entities + relations only, no source text. Hybrid changes which entities *seed*, never what *egresses*.

---

## 7. Latency budget (read path)

Measured `gte-small` ≈ 119 ms/embedding. Read path adds: 1 query embedding (~119 ms) + one HNSW-indexed RPC (~single-digit ms) ⇒ **~120–150 ms** on top of Phase 1's ~1.2 s (auth/DB-bound). Acceptable for a background tool call. Write-path embedding is async, off the user's turn.

---

## 8. Testing

- **Semantic-only eval scenario (new), zero lexical overlap:** query `"startup"`, entity name `"Northwind"` with description `"a venture-backed company"` — **no shared token** with the query, so BM25 (name+description) *cannot* match; only the vector path connects them. Assert it is seeded. (Uses the local `Embedder` stub + fixture vectors engineered so `startup`≈`venture-backed company`.) This is the case that fails without pgvector.
- **Match fn tests (live DB):** (a) given fixture vectors across **two** notebooks, `match_entity_embeddings` returns only the queried notebook's nearest ids (exact per-notebook, no cross-notebook leakage, 100% within-notebook recall); (b) `p_limit` is clamped (request 9999 → ≤50); (c) **a user-JWT call to the function is denied** (`authenticated` revoked) — proves the rate-limit bypass is closed.
- **No lexical regression:** existing 7 scenarios (run with `extraSeeds = none`) stay 7/7.
- **`extraSeeds` merge test:** semantic ∪ lexical (max per id); k-hop expands from the merged set.
- **Drift guard:** `check-graphloop-sync.mjs` green after the shared `retrieve.ts` change (re-sync vendored).
- **Trigger + reconcile test (live DB):** a single bulk entity insert fires `embed-entities` **once** (statement-level) → vector rows appear; edit an entity's description → its vector updates (hash changed); remove an entity from the next save → its vector row is pruned; a **web-originated** save also embeds (client-agnostic trigger).
- **Deployed parity + source-free** re-verified after deploy.

---

## 9. Risks & Known Limitations

- **Freshness lag:** a just-created entity has no vector until the async reconcile lands (~seconds); lexical/exact-name seeding covers it meanwhile. New entities are usually named explicitly.
- **Snapshot churn:** saves delete+insert all entities in one statement; the **statement-level** insert trigger fires once per save (client-agnostic) and the reconcile (hash-diff embed + orphan prune) keeps `entity_embeddings` consistent without a per-row storm. `pg_cron` backstops dropped `pg_net` calls and `clearState` deletes.
- **CPU limit (measured):** `embed-entities` chunks ≤10; large notebooks reconcile across invocations.
- **Exact scan scale ceiling:** exact per-notebook scan is 100% recall and fast at journal scale (tens of entities/notebook). If a notebook grows to thousands of entities the scan slows — the scale-up path is HNSW + `hnsw.iterative_scan` (deferred; not needed now).
- **Ranker dominance:** semantic seeds enter as seed *relevance*; the composite ranker (recency/importance/confidence) still governs final order, so a weak vector match can't dominate. Threshold + weight tunable.

---

## 10. Prerequisites

- `vector` + `pg_net` extensions (enabled in the migration); `pg_cron` for the backstop.
- An internal secret (Vault/DB setting) for the trigger→function call; `SUPABASE_SERVICE_ROLE_KEY` available to **both** `embed-entities` (write) and `retrieve-memory` (the service-role match call).
- Phase 1 deployed (done) + `saveState` `user_id` fix (done) so entities persist and the trigger can reconcile.

---

## 11. Implementation Gate

Do not ship until: migration (`entity_embeddings` locked + notebook btree, service-role-only `match_entity_embeddings` with clamped limit, extensions) applied; `embed-entities` deployed (internal-secret-gated, service-role, chunked ≤10, reconcile + prune); **statement-level insert trigger on `entities`** + `pg_net` firing once per save (verified on both apps); `pg_cron` backstop; `retrieve-memory` semantic seeding via the service-role match, fail-closed; a user-JWT call to the match fn denied; `retrieve()` `extraSeeds` in **both** graphloop copies, drift guard green; `Embedder` stub; new zero-overlap semantic eval passing + existing 7 still passing; deployed parity + source-free re-verified.

---

## 12. Sequential Build Steps

1. **Migration** — `vector`/`pg_net` extensions; locked `entity_embeddings` (RLS on, no policy, revoked grants) + notebook btree; service-role-only `match_entity_embeddings` (clamped `p_limit`).
2. **`Embedder` interface** + prod (`gte-small`) + local stub; unit-test stub determinism.
3. **`retrieve()` `extraSeeds`** — both graphloop copies, re-sync vendored, drift guard green; merge unit test; 7-scenario harness still 7/7.
4. **`embed-entities` edge fn** — internal-secret check, service-role reconcile (hash-diff embed ≤10 + orphan prune); deploy; live reconcile test.
5. **Trigger + `pg_net` + `pg_cron`** — statement-level `after insert on entities` (transition table → distinct notebook_ids) → `embed-entities`; backfill existing entities; backstop job. Verify a **web** save embeds too.
6. **`retrieve-memory` semantic seeding** — query embed → service-role `match_entity_embeddings` → `extraSeeds` → `retrieve()`, fail-closed; deploy.
7. **Eval + verify** — zero-overlap semantic scenario (local stub + fixture vectors); re-run harness; live deployed parity + source-free smoke.

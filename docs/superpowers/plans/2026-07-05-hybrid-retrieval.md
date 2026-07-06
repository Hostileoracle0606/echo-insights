# Phase 2a — Hybrid (Semantic) Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add semantic (vector) seeds to retrieval — entities embedded once at write time (pgvector + native `gte-small`), query embedded at read — merged into graphloop's existing lexical + k-hop + ranking pipeline, with the source-free output and all Phase 1 gates unchanged.

**Architecture:** Embed-once-search-many. A locked `entity_embeddings` table holds per-entity vectors, written by an internal `embed-entities` edge function (fired by a statement-level `entities` insert trigger, reconciles via hash+model diff, chunk ≤10 with `fetch()` self-reenqueue, prunes orphans; `pg_cron` backstops). `retrieve-memory` embeds the query, calls a **service-role-only** `match_entity_embeddings` (exact per-notebook cosine scan, model-filtered), and passes the results as `extraSeeds` into a shared `retrieve()` change.

**Tech Stack:** Deno edge functions (TS), Supabase Postgres + pgvector + pg_net + pg_cron, native `gte-small` (384-dim), vendored graphloop (TS), vitest (web graphloop tests), `deno test`.

**Spec:** [docs/superpowers/specs/2026-07-05-hybrid-retrieval-design.md](../specs/2026-07-05-hybrid-retrieval-design.md)

**Env note:** `deno` is at `~/.deno/bin/deno` (not on PATH). Tasks 1–3 + 5/7 (deno check) run locally now; Tasks 4/6 write SQL; **Task 8 needs the live Supabase env** (migrations, deploy, JWT) and is the user's to run — same split as Phase 1.

---

## File Structure

- Modify: `src/lib/graphloop/retrieve.ts` — `RetrieveDeps.extraSeeds` + merge into seed selection (shared change).
- Regenerate: `supabase/functions/_shared/graphloop/retrieve.ts` — via `node scripts/sync-graphloop.mjs`.
- Create: `supabase/functions/_shared/embedder.ts` — `Embedder` interface + `GteSmallEmbedder` (prod) + `StubEmbedder` (test).
- Create: `supabase/functions/_shared/embedder.test.ts` — stub determinism.
- Modify: `supabase/functions/retrieve-memory/eval.ts` — `extraSeeds` support + semantic-only scenario + control.
- Create: `supabase/migrations/20260705000000_entity_embeddings.sql` — locked table + `match_entity_embeddings` + extensions.
- Create: `supabase/migrations/20260705000001_entity_embeddings_trigger.sql` — statement trigger + 2 `pg_cron` sweeps.
- Create: `supabase/functions/embed-entities/index.ts` — reconcile edge fn.
- Modify: `supabase/config.toml` — `[functions.embed-entities] verify_jwt = false`.
- Modify: `supabase/functions/retrieve-memory/index.ts` — query embed + service-role match + `extraSeeds`.

---

## Task 1: graphloop `extraSeeds` (shared change, both copies)

**Files:**
- Modify: `src/lib/graphloop/retrieve.ts`
- Test: `src/lib/graphloop/retrieve.test.ts`
- Regenerate: `supabase/functions/_shared/graphloop/retrieve.ts`

- [ ] **Step 1: Write the failing test**

Append this `describe` block to `src/lib/graphloop/retrieve.test.ts`. **Do not add imports** — the file already imports `describe`, `test`, `expect`, `SearchIndex`, `retrieve`, and `GraphState` (via `./types`) at the top:

```ts
describe("retrieve extraSeeds", () => {
  const t = "2026-07-05T00:00:00Z";
  const state: GraphState = {
    entities: {
      northwind: { id: "northwind", name: "Northwind", type: "project", metadata: {}, mentions: 2, firstSeen: t, lastSeen: t, description: "a venture-backed company" },
    },
    relations: {},
    entries: [],
  };

  async function run(extraSeeds?: Map<string, number>) {
    const index = new SearchIndex();
    await index.sync(Object.values(state.entities));
    return retrieve(state, "startup", { mode: "lexical" }, { index, extraSeeds });
  }

  test("does NOT seed a no-lexical-overlap entity without extraSeeds", async () => {
    const r = await run();
    expect(r.entities.map((e) => e.id)).not.toContain("northwind");
  });

  test("seeds it when extraSeeds supplies it", async () => {
    const r = await run(new Map([["northwind", 0.9]]));
    expect(r.entities.map((e) => e.id)).toContain("northwind");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run src/lib/graphloop/retrieve.test.ts -t extraSeeds`
Expected: the second test FAILS (extraSeeds not honored → northwind absent). (First may pass already.)

- [ ] **Step 3: Add `extraSeeds` to `RetrieveDeps`**

In `src/lib/graphloop/retrieve.ts`, extend the interface (currently ends at `now?: number;`):

```ts
export interface RetrieveDeps {
  index: SearchIndex;
  embedModel?: EmbeddingModel;
  communities?: CommunitySummary[];
  now?: number;
  /** Externally-computed semantic seeds (entity-id → relevance in [0,1]); unioned with lexical seeds. */
  extraSeeds?: Map<string, number>;
}
```

- [ ] **Step 4: Merge `extraSeeds` in seed selection**

In `src/lib/graphloop/retrieve.ts`, immediately **after** the exact-normalized-name block (the `for (const e of Object.values(state.entities)) { ... }` that ends with the `seedScore.set(e.id, ...)` line) and **before** `const seeds = [...seedScore.keys()]...`, insert:

```ts
  // externally-supplied semantic seeds (hybrid) — union by max score
  if (deps.extraSeeds) {
    for (const [id, score] of deps.extraSeeds) {
      if (state.entities[id]) seedScore.set(id, Math.max(seedScore.get(id) ?? 0, score));
    }
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npx vitest run src/lib/graphloop/retrieve.test.ts -t extraSeeds`
Expected: PASS (both).

- [ ] **Step 6: No regression across graphloop tests**

Run: `npx vitest run src/lib/graphloop/`
Expected: all existing graphloop tests still pass.

- [ ] **Step 7: Re-sync the vendored copy + drift guard**

Run: `node scripts/sync-graphloop.mjs && node scripts/check-graphloop-sync.mjs`
Expected: prints the sync line, then `graphloop vendored copy is in sync` (exit 0). This regenerates `supabase/functions/_shared/graphloop/retrieve.ts` with the same change.

- [ ] **Step 8: Confirm the edge-side harness still passes (no regression)**

Run: `~/.deno/bin/deno run -A supabase/functions/retrieve-memory/eval.ts`
Expected: `7/7 passed` (the existing scenarios don't pass `extraSeeds`, so behavior is unchanged).

- [ ] **Step 9: Commit**

```bash
git add src/lib/graphloop/retrieve.ts src/lib/graphloop/retrieve.test.ts supabase/functions/_shared/graphloop/retrieve.ts
git commit -m "feat(graphloop): optional extraSeeds merged into seed selection (shared)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Embedder` interface + stub + gte-small

**Files:**
- Create: `supabase/functions/_shared/embedder.ts`
- Test: `supabase/functions/_shared/embedder.test.ts`

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/_shared/embedder.test.ts`:

```ts
import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "./embedder.ts";

Deno.test("StubEmbedder is deterministic, 384-dim, normalized-ish", async () => {
  const e = new StubEmbedder();
  assertEquals(e.modelId, "stub@1");
  const [a] = await e.embed(["hello world"]);
  const [b] = await e.embed(["hello world"]);
  assertEquals(a.length, 384);
  assertEquals(a, b); // deterministic
});

Deno.test("StubEmbedder distinguishes different text", async () => {
  const e = new StubEmbedder();
  const [a] = await e.embed(["startup"]);
  const [b] = await e.embed(["completely different tokens here"]);
  assert(JSON.stringify(a) !== JSON.stringify(b));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/.deno/bin/deno test supabase/functions/_shared/embedder.test.ts`
Expected: FAIL — module `./embedder.ts` not found.

- [ ] **Step 3: Write the implementation**

Create `supabase/functions/_shared/embedder.ts`:

```ts
// Pluggable embedding provider. Prod uses the native gte-small model available
// only in the Supabase edge runtime; the stub runs anywhere (local tests/eval).
export interface Embedder {
  readonly modelId: string;
  embed(texts: string[]): Promise<number[][]>;
}

const DIM = 384;

/** Native gte-small (384-dim). `Supabase.ai` exists only in the deployed edge runtime. */
export class GteSmallEmbedder implements Embedder {
  readonly modelId = "gte-small@1";
  // deno-lint-ignore no-explicit-any
  #session = new (globalThis as any).Supabase.ai.Session("gte-small");
  async embed(texts: string[]): Promise<number[][]> {
    const out: number[][] = [];
    for (const t of texts) {
      out.push(await this.#session.run(t, { mean_pool: true, normalize: true }) as number[]);
    }
    return out;
  }
}

/** Deterministic hash-feature stub for local tests/eval (no Supabase.ai). */
export class StubEmbedder implements Embedder {
  readonly modelId = "stub@1";
  async embed(texts: string[]): Promise<number[][]> {
    return texts.map((t) => {
      const v = new Array<number>(DIM).fill(0);
      for (const tok of t.toLowerCase().split(/\s+/).filter(Boolean)) {
        let h = 2166136261;
        for (let i = 0; i < tok.length; i++) { h ^= tok.charCodeAt(i); h = Math.imul(h, 16777619); }
        v[Math.abs(h) % DIM] += 1;
      }
      const norm = Math.hypot(...v) || 1;
      return v.map((x) => x / norm);
    });
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/.deno/bin/deno test supabase/functions/_shared/embedder.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/embedder.ts supabase/functions/_shared/embedder.test.ts
git commit -m "feat: pluggable Embedder (native gte-small + deterministic test stub)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: eval — semantic-only scenario + control

**Files:**
- Modify: `supabase/functions/retrieve-memory/eval.ts`

- [ ] **Step 1: Add `extraSeeds` to the `Scenario` interface**

In `supabase/functions/retrieve-memory/eval.ts`, add a field to the `Scenario` interface (next to `sentinel?`):

```ts
  extraSeeds?: Record<string, number>;   // simulated semantic seeds (id → score)
```

- [ ] **Step 2: Pass `extraSeeds` into `retrieve` in the runner**

In the `run(s: Scenario)` function, change the `retrieve(...)` call from:

```ts
  const result = await retrieve(s.state, s.query, { mode: "lexical" }, { index: idx, communities });
```

to:

```ts
  const result = await retrieve(s.state, s.query, { mode: "lexical" }, {
    index: idx,
    communities,
    extraSeeds: s.extraSeeds ? new Map(Object.entries(s.extraSeeds)) : undefined,
  });
```

- [ ] **Step 3: Add the semantic-only scenario + control**

Add two scenarios to the `scenarios` array. The entity has **zero token overlap** with the query, so lexical cannot seed it; only the (simulated) semantic seed can:

```ts
  {
    id: "S8 semantic-seed",
    behavior: "A no-lexical-overlap entity IS recalled when a semantic seed supplies it",
    query: "startup",
    state: graph(
      [ent("northwind", "Northwind", "project", { description: "a venture-backed company", mentions: 2 }),
       ent("maya", "Maya", "person", { mentions: 1 })],
      [rel("r1", "maya", "works_at", "northwind")],
    ),
    extraSeeds: { northwind: 0.82 },
    expectRelevant: ["Northwind", "Maya"],
  },
  {
    id: "S9 semantic-control",
    behavior: "Same graph, NO semantic seed → lexical alone cannot find it (proves the vector path is load-bearing)",
    query: "startup",
    state: graph(
      [ent("northwind", "Northwind", "project", { description: "a venture-backed company", mentions: 2 })],
      [],
    ),
    expectRelevant: [],
    expectEmpty: true,
  },
```

- [ ] **Step 4: Run the eval**

Run: `~/.deno/bin/deno run -A supabase/functions/retrieve-memory/eval.ts`
Expected: `9/9 passed` — S8 seeds Northwind via `extraSeeds`; S9 (no seed, no lexical overlap) returns empty, proving the semantic path is what makes S8 work.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/retrieve-memory/eval.ts
git commit -m "test: semantic-seed eval scenario + no-seed control (zero lexical overlap)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Migration — locked `entity_embeddings` + `match_entity_embeddings`

**Files:**
- Create: `supabase/migrations/20260705000000_entity_embeddings.sql`

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260705000000_entity_embeddings.sql`:

```sql
create extension if not exists vector;
create extension if not exists pg_net;

-- Per-entity embedding, versioned by embedding_model. Operational state:
-- clients get zero direct access (RLS on, no policy, grants revoked).
create table public.entity_embeddings (
  notebook_id     uuid not null references public.notebooks(id) on delete cascade,
  entity_id       text not null,
  user_id         uuid not null references auth.users(id) on delete cascade,
  embedding       vector(384) not null,
  embedding_model text not null,
  content_hash    text not null,
  updated_at      timestamptz not null default now(),
  primary key (notebook_id, entity_id)
);

alter table public.entity_embeddings enable row level security;
revoke all on table public.entity_embeddings from anon, authenticated;

-- Per-notebook btree; exact scan within a notebook (no HNSW at this scale).
create index entity_embeddings_notebook on public.entity_embeddings (notebook_id);

-- Service-role-only match: exact per-notebook cosine, model-filtered, clamped.
-- Not granted to authenticated → cannot be called directly to bypass the edge
-- fn's ownership + rate-limit gates.
create or replace function public.match_entity_embeddings(
  p_notebook_id uuid, p_query vector(384), p_limit int, p_model text
) returns table (entity_id text, score float)
language sql stable as $$
  select e.entity_id, 1 - (e.embedding <=> p_query) as score
  from public.entity_embeddings e
  where e.notebook_id = p_notebook_id
    and e.embedding_model = p_model
  order by e.embedding <=> p_query
  limit least(greatest(p_limit, 1), 50);
$$;
revoke all on function public.match_entity_embeddings(uuid, vector, int, text) from public, anon, authenticated;
grant execute on function public.match_entity_embeddings(uuid, vector, int, text) to service_role;
```

- [ ] **Step 2: Sanity-check the SQL parses (local, no DB)**

Run: `grep -c "create " supabase/migrations/20260705000000_entity_embeddings.sql`
Expected: `5` (vector ext, pg_net ext, table, index, match function); visually confirm the file matches Step 1. (Applying to the live DB happens in Task 8.)

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260705000000_entity_embeddings.sql
git commit -m "feat(db): locked entity_embeddings + service-role match_entity_embeddings

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `embed-entities` edge function (reconcile)

**Files:**
- Create: `supabase/functions/embed-entities/index.ts`
- Modify: `supabase/config.toml`

- [ ] **Step 1: Write the function**

Create `supabase/functions/embed-entities/index.ts`:

```ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GteSmallEmbedder } from "../_shared/embedder.ts";

const CHUNK = 10;

async function contentHash(name: string, description: string | null): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${name}\n${description ?? ""}`),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  // Internal-only: gated by a shared secret, not a user JWT.
  if (req.headers.get("x-internal-secret") !== Deno.env.get("EMBED_INTERNAL_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const { notebookId } = (await req.json()) as { notebookId: string };
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const embedder = new GteSmallEmbedder();

  // Authoritative owner from notebooks (NOT from entity rows).
  const { data: nb } = await admin.from("notebooks").select("user_id").eq("id", notebookId).single();
  if (!nb) return Response.json({ ok: false, reason: "notebook gone" });
  const owner = nb.user_id as string;

  // Filter by user_id = owner: entity insert RLS only checks auth.uid() = user_id,
  // NOT notebook ownership, so a foreign user could inject rows into this
  // notebook_id. Embedding only the owner's own rows neutralizes that here.
  // (Hardening the entities insert/update policy to also check notebook
  // ownership is the deeper pre-existing fix, tracked separately in the spec.)
  const { data: entities } = await admin
    .from("entities").select("id,name,description").eq("notebook_id", notebookId).eq("user_id", owner);
  const rows = entities ?? [];
  const { data: existing } = await admin
    .from("entity_embeddings").select("entity_id,content_hash,embedding_model").eq("notebook_id", notebookId);
  const have = new Map((existing ?? []).map((r) => [r.entity_id, r]));

  // Prune orphans for this notebook.
  const currentIds = new Set(rows.map((r) => r.id));
  const orphans = (existing ?? []).map((r) => r.entity_id).filter((id) => !currentIds.has(id));
  if (orphans.length) {
    await admin.from("entity_embeddings").delete().eq("notebook_id", notebookId).in("entity_id", orphans);
  }

  // Stale = missing OR content changed OR model changed.
  const stale: { id: string; name: string; description: string | null; hash: string }[] = [];
  for (const r of rows) {
    const hash = await contentHash(r.name, r.description);
    const cur = have.get(r.id);
    if (!cur || cur.content_hash !== hash || cur.embedding_model !== embedder.modelId) {
      stale.push({ id: r.id, name: r.name, description: r.description, hash });
    }
  }

  const batch = stale.slice(0, CHUNK);
  if (batch.length) {
    const vecs = await embedder.embed(batch.map((s) => `${s.name}\n${s.description ?? ""}`));
    await admin.from("entity_embeddings").upsert(
      batch.map((s, i) => ({
        notebook_id: notebookId, entity_id: s.id, user_id: owner,
        embedding: JSON.stringify(vecs[i]), embedding_model: embedder.modelId, content_hash: s.hash,
        updated_at: new Date().toISOString(),
      })),
    );
  }

  // Continuation: more remain → re-enqueue self via fetch (NOT net.http_post,
  // which is Postgres-only). Wrap in EdgeRuntime.waitUntil so the runtime does
  // not cancel the in-flight reenqueue when this invocation returns; the cron
  // reconcile sweep remains the final backstop if it still drops.
  if (batch.length === CHUNK && stale.length > CHUNK) {
    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/embed-entities`;
    const reenqueue = fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-internal-secret": Deno.env.get("EMBED_INTERNAL_SECRET")! },
      body: JSON.stringify({ notebookId }),
    }).catch(() => {});
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil?.(reenqueue);
  }

  return Response.json({ ok: true, embedded: batch.length, remaining: Math.max(0, stale.length - batch.length), pruned: orphans.length });
});
```

- [ ] **Step 2: Register the function (no JWT — internal secret gated)**

Append to `supabase/config.toml`:

```toml
[functions.embed-entities]
verify_jwt = false
```

- [ ] **Step 3: Typecheck**

Run: `~/.deno/bin/deno check supabase/functions/embed-entities/index.ts`
Expected: no errors in `index.ts` (esm.sh types download on first run).

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/embed-entities/index.ts supabase/config.toml
git commit -m "feat: embed-entities reconcile fn (service-role, hash+model diff, chunked self-reenqueue, prune)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Trigger + `pg_cron` backstop (migration)

**Files:**
- Create: `supabase/migrations/20260705000001_entity_embeddings_trigger.sql`

- [ ] **Step 1: Write the migration**

Create `supabase/migrations/20260705000001_entity_embeddings_trigger.sql`. Set the two settings (function URL + secret) via `alter database ... set` or Vault; the function reads them through `current_setting`:

```sql
create extension if not exists pg_cron;

-- Fire once per bulk entity insert (statement level). Transition table gives the
-- affected notebook_ids without a per-row storm; user_id is resolved in the fn.
create or replace function public.enqueue_embed_entities()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := current_setting('app.embed_entities_url', true);
  v_secret text := current_setting('app.embed_internal_secret', true);
begin
  -- Config not set yet → skip quietly (never break the save); cron reconcile covers it.
  if v_url is null or v_url = '' then return null; end if;
  for r in select distinct notebook_id from new_rows loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id)
    );
  end loop;
  return null;
end $$;

create trigger entities_embed_enqueue
  after insert on public.entities
  referencing new table as new_rows
  for each statement execute function public.enqueue_embed_entities();

-- Backstop sweep A: poke EVERY notebook that has entities. embed-entities is
-- idempotent and does the precise staleness check (missing OR content_hash OR
-- embedding_model changed) as the single source of truth — so this one query
-- catches dropped webhooks, description edits, AND model migrations without
-- duplicating the SHA-256 / model-id logic in SQL. (Scale-up, if invocation
-- volume ever matters: narrow to notebooks with a provably-stale row using
-- pgcrypto digest + an app.embedding_model setting.)
create or replace function public.embed_reconcile_sweep()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_url text := current_setting('app.embed_entities_url', true);
  v_secret text := current_setting('app.embed_internal_secret', true);
begin
  if v_url is null or v_url = '' then return; end if;
  for r in select distinct notebook_id from public.entities loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
      body    := jsonb_build_object('notebookId', r.notebook_id));
  end loop;
end $$;

-- Backstop sweep B: global orphan prune (catches clearState / zero-entity saves
-- that never fire the insert trigger).
create or replace function public.embed_orphan_prune()
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from public.entity_embeddings ee
  where not exists (
    select 1 from public.entities e
    where e.notebook_id = ee.notebook_id and e.id = ee.entity_id);
$$;

-- Reconcile is a full sweep now → every 15 min (trigger handles the hot path).
select cron.schedule('embed-reconcile', '*/15 * * * *', 'select public.embed_reconcile_sweep()');
select cron.schedule('embed-orphan-prune', '*/30 * * * *', 'select public.embed_orphan_prune()');
```

- [ ] **Step 2: Sanity-check parse (local)**

Run: `grep -cE "create (or replace )?function|create trigger|cron.schedule" supabase/migrations/20260705000001_entity_embeddings_trigger.sql`
Expected: `6` (3 functions + 1 trigger + 2 schedules). Visually confirm against Step 1. (Apply in Task 8; also set `app.embed_entities_url` + `app.embed_internal_secret` there.)

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260705000001_entity_embeddings_trigger.sql
git commit -m "feat(db): statement-level embed trigger + pg_cron reconcile & orphan-prune sweeps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `retrieve-memory` semantic seeding

**Files:**
- Modify: `supabase/functions/retrieve-memory/index.ts`

- [ ] **Step 1: Import the embedder**

At the top of `supabase/functions/retrieve-memory/index.ts`, add after the existing imports:

```ts
import { GteSmallEmbedder } from "../_shared/embedder.ts";
```

- [ ] **Step 2: Compute semantic seeds before the retrieve call**

In the handler, find:

```ts
    if (!query || Object.keys(entities).length === 0) return json(200, { context: "" });

    const g = { entities, relations, entries } as unknown as GraphState;
    const index = new SearchIndex();
    await index.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    const result = await retrieve(g, query, { mode: "lexical" }, { index, communities });
```

Replace it with (embed query → service-role match → `extraSeeds`; fail-closed):

```ts
    if (!query || Object.keys(entities).length === 0) return json(200, { context: "" });

    // ── Semantic seeds (hybrid). Service-role, downstream of ownership + rate.
    // Fail-closed: any failure → no extraSeeds → Phase 1 lexical behavior.
    let extraSeeds: Map<string, number> | undefined;
    try {
      const embedder = new GteSmallEmbedder();
      const [qvec] = await embedder.embed([query]);
      const admin = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      );
      const { data: matches } = await admin.rpc("match_entity_embeddings", {
        p_notebook_id: notebookId,
        p_query: `[${qvec.join(",")}]`, // vector literal — reliable across PostgREST
        p_limit: 12,
        p_model: embedder.modelId,
      });
      if (Array.isArray(matches)) {
        extraSeeds = new Map(
          (matches as { entity_id: string; score: number }[])
            .filter((m) => m.score >= 0.7)
            .map((m) => [m.entity_id, m.score]),
        );
      }
    } catch {
      extraSeeds = undefined;
    }

    const g = { entities, relations, entries } as unknown as GraphState;
    const index = new SearchIndex();
    await index.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    const result = await retrieve(g, query, { mode: "lexical" }, { index, communities, extraSeeds });
```

- [ ] **Step 3: Typecheck + no-regression on the context tests**

Run: `~/.deno/bin/deno check supabase/functions/retrieve-memory/index.ts`
Expected: no new errors in `index.ts` (the known graphology `communities.ts` type errors may remain).
Run: `~/.deno/bin/deno test supabase/functions/retrieve-memory/context.test.ts`
Expected: 2 passed (context builder unchanged).

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/retrieve-memory/index.ts
git commit -m "feat: retrieve-memory hybrid seeding via service-role match (fail-closed)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Deploy & live verification (requires Supabase env — user-run)

**Files:** none. **Mutates the live backend — run only against `bjoevzvsdlhlcjywpyfx` (deploy preflight from the Phase 1 plan applies).**

- [ ] **Step 1: Set secrets + settings**

```bash
supabase secrets set EMBED_INTERNAL_SECRET="$(openssl rand -hex 32)" --project-ref bjoevzvsdlhlcjywpyfx
# SUPABASE_SERVICE_ROLE_KEY is injected into functions by the platform.
# Set the DB settings the trigger reads (psql to the project):
#   alter database postgres set app.embed_entities_url = 'https://bjoevzvsdlhlcjywpyfx.supabase.co/functions/v1/embed-entities';
#   alter database postgres set app.embed_internal_secret = '<same value as EMBED_INTERNAL_SECRET>';
```

- [ ] **Step 2: Apply migrations**

Run: `supabase db push` (review `--dry-run` first). Expected: the two 20260705 migrations apply; `entity_embeddings`, `match_entity_embeddings`, trigger, and cron jobs exist.

- [ ] **Step 3: Deploy both functions**

```bash
supabase functions deploy embed-entities --project-ref bjoevzvsdlhlcjywpyfx --use-api
supabase functions deploy retrieve-memory --project-ref bjoevzvsdlhlcjywpyfx --import-map supabase/functions/retrieve-memory/deno.json --use-api
```
Expected: both deploy ACTIVE.

- [ ] **Step 4: Backfill existing entities**

For each existing notebook, POST `embed-entities` with the internal secret (or wait for the 15-min reconcile sweep). Verify vector rows appear:
```bash
# with service-role or SQL: select count(*) from entity_embeddings;  → > 0
```

- [ ] **Step 5: Live checks**

- **Trigger fires once/save:** save a notebook (web or Flutter) → within seconds `entity_embeddings` has rows for its entities (statement-level, one embed pass).
- **>10 continuation:** a notebook with 25 entities ends up fully embedded (self-reenqueue).
- **Orphan prune:** `clearState` a notebook → after the 30-min prune sweep (or manual `select public.embed_orphan_prune()`), its rows are gone.
- **Semantic recall:** create an entity `Northwind` described "a venture-backed company"; after it embeds, a `retrieve-memory` call with query `"startup"` seeds Northwind (which lexical alone would miss). Confirm the response is still source-free.
- **Match not user-callable:** `curl` the RPC directly with a user JWT → permission denied (granted only to `service_role`).

- [ ] **Step 6: Re-run the deployed source-free smoke (Phase 1 valid-call)**

Confirm the deployed `retrieve-memory` still returns `## Entities`/`## Relations`, no `## Sources`, no sentinel — hybrid didn't change the output contract.

---

## Self-Review Notes (completed by plan author)

- **Spec coverage:** §5.1 table+match → Task 4; §5.2 embed-entities+trigger+cron → Tasks 5, 6; §5.3 read seeding → Task 7; §5.4 `extraSeeds` (both copies) → Task 1; §5.5 Embedder → Task 2; §8 tests → Tasks 1–3 (local) + Task 8 (live); §7 latency / §6 privacy / §9 risks → enforced by Tasks 4/7 (service-role, model filter, source-free unchanged). Gate §11 → Task 8.
- **Type consistency:** `extraSeeds: Map<string, number>` (Task 1) matches the runner (Task 3) and retrieve-memory (Task 7); `Embedder.modelId`/`embed()` (Task 2) used in Tasks 5, 7; `match_entity_embeddings(uuid, vector, int, text)` (Task 4) matches the RPC call args (Task 7); vector passed as a `[...]` string literal (Task 7) for PostgREST reliability.
- **No placeholders:** every code step shows complete code; DB-apply/deploy steps that need live env are isolated in Task 8.

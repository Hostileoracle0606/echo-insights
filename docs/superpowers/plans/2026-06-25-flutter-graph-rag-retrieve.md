# Flutter Graph-RAG Retrieve & Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Flutter voice agent a `get_relevant_memory({ query })` tool backed by the web app's existing graphloop `retrieve()`, run server-side in a Supabase edge function fed the live `JournalState`, returning a source-free (entities + relations only) context packet.

**Architecture:** A new `retrieve-memory` edge function vendors the graphloop retrieval subset into `supabase/functions/_shared/graphloop/` (Deno needs explicit `.ts` extensions + an import map for bare npm specifiers; the unused `embed.ts` is stubbed to drop the `ai` dep). The function verifies the JWT + notebook ownership, runs `retrieve()` in lexical mode, and rebuilds the returned `context` from entities + relations only — verbatim journal entry text never egresses. Flutter calls it via `functions.invoke`, serializing `JournalState` into graphloop's **camelCase** shape (NOT the Dart models' snake_case `toJson()`).

**Tech Stack:** Deno (Supabase Edge Functions), TypeScript, graphloop (@orama/orama 3.1.18, graphology 0.26.0, graphology-communities-louvain 2.0.2), Dart/Flutter, Riverpod, supabase_flutter, flutter_test.

**Spec:** [docs/superpowers/specs/2026-06-25-flutter-graph-rag-retrieve-design.md](../specs/2026-06-25-flutter-graph-rag-retrieve-design.md)

**Prerequisite (separate work, not in this plan):** Flutter `saveState` omits `user_id` and would violate RLS (spec §11). Independent of retrieval (which uses body state), but gates cross-session persistence. Tracked separately.

---

## File Structure

**Edge function (Deno/TS):**
- Create: `supabase/functions/retrieve-memory/context.ts` — pure `buildContext()` (no side effects, test-importable).
- Create: `supabase/functions/retrieve-memory/index.ts` — HTTP handler: auth, ownership, input caps, retrieval; imports `buildContext`. Calls `serve()` at top level, so it is NOT imported by tests.
- Create: `supabase/functions/retrieve-memory/deno.json` — import map pinning bare specifiers to esm.sh.
- Create: `supabase/functions/retrieve-memory/context.test.ts` — Deno tests for `buildContext` (imports `context.ts`, never `index.ts`, to avoid starting the server).
- Create: `supabase/functions/_shared/graphloop/*.ts` — vendored graphloop retrieval subset (generated).
- Create: `scripts/sync-graphloop.mjs` — copies `src/lib/graphloop` → `_shared/graphloop`, rewrites relative imports to `.ts`, stubs `embed.ts`.
- Create: `scripts/check-graphloop-sync.mjs` — drift guard: re-runs sync into a temp dir, fails if `_shared/graphloop` differs.
- Modify: `supabase/config.toml` — register `[functions.retrieve-memory]`.

**Flutter (Dart):**
- Create: `lib/services/retrieve_memory_service.dart` — `stateToGraphloop()` serializer + `RetrieveMemoryService.retrieve()`.
- Create: `test/retrieve_memory_service_test.dart` — serialization parity test.
- Modify: `lib/logic/conversation_policy.dart` — add `get_relevant_memory` prompt block (source-free wording).
- Modify: `lib/providers/journal_provider.dart` — register the tool, wire `onToolCall`, over-call guardrails.

---

## Task 1: Vendor graphloop into the edge function

Deno cannot consume `src/lib/graphloop` directly: its relative imports are extensionless (`from "./types"`) and it uses bare npm specifiers. This task generates a Deno-compatible copy under `_shared/graphloop` and a drift guard.

**Files:**
- Create: `scripts/sync-graphloop.mjs`
- Create: `scripts/check-graphloop-sync.mjs`
- Create: `supabase/functions/retrieve-memory/deno.json`
- Generated: `supabase/functions/_shared/graphloop/*.ts`

- [ ] **Step 1: Write the sync script**

Create `scripts/sync-graphloop.mjs`:

```js
// Copies the graphloop retrieval subset into the edge function's _shared dir,
// rewriting for Deno: explicit .ts extensions on relative imports, and a stub
// for embed.ts (never called in lexical mode) so the `ai` dep is dropped.
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(root, "src/lib/graphloop");
const FILES = ["types.ts", "noise.ts", "graph-ops.ts", "search-index.ts", "communities.ts", "retrieve.ts"];

// embed.ts is value-imported by retrieve.ts but never invoked in lexical mode.
// Stub it so the vendored copy carries no dependency on the `ai` package.
const EMBED_STUB = `// Generated stub — lexical-only retrieval never calls embedTexts.
import type { EmbeddingModel } from "./types.ts";
export async function embedTexts(_model: EmbeddingModel, _texts: string[]): Promise<number[][]> {
  throw new Error("embedTexts is stubbed in the edge function (lexical mode only)");
}
`;

// retrieve.ts imports EmbeddingModel from "ai"; repoint it at a local alias so
// the vendored copy needs no `ai` import. types.ts gains the alias (Step 2 note).
export function transform(file, body) {
  if (file === "embed.ts") return EMBED_STUB;
  let out = body.replace(/from "(\.[^"]+)"/g, (m, p) => (p.endsWith(".ts") ? m : `from "${p}.ts"`));
  if (file === "retrieve.ts") {
    out = out.replace(/import type \{ EmbeddingModel \} from "ai";/, `import type { EmbeddingModel } from "./types.ts";`);
  }
  return out;
}

export function syncInto(destDir) {
  rmSync(destDir, { recursive: true, force: true });
  mkdirSync(destDir, { recursive: true });
  for (const f of [...FILES, "embed.ts"]) {
    const body = f === "embed.ts" ? "" : readFileSync(join(SRC, f), "utf8");
    writeFileSync(join(destDir, f), transform(f, body));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  syncInto(join(root, "supabase/functions/_shared/graphloop"));
  console.log("synced graphloop -> supabase/functions/_shared/graphloop");
}
```

- [ ] **Step 2: Export a local `EmbeddingModel` type from graphloop types**

The vendored `retrieve.ts` and `embed.ts` reference `EmbeddingModel` only as a type, and the Step 1 transform repoints `retrieve.ts`'s `import type { EmbeddingModel } from "ai"` to `from "./types.ts"`. So `types.ts` must export that name. Append to the end of `src/lib/graphloop/types.ts`:

```ts
// Local structural alias so the Deno edge-function copy needs no `ai` import.
// The web build imports the real EmbeddingModel from "ai", so this export is
// unused there and changes no web behavior.
export type EmbeddingModel = { readonly modelId?: string };
```

This is the single source file edited outside the vendoring; it is additive and the drift guard (Step 4) re-copies it into `_shared/graphloop/types.ts`.

- [ ] **Step 3: Run the sync script**

Run: `node scripts/sync-graphloop.mjs`
Expected: prints `synced graphloop -> supabase/functions/_shared/graphloop` and creates `supabase/functions/_shared/graphloop/{types,noise,graph-ops,search-index,communities,retrieve,embed}.ts`.

- [ ] **Step 4: Write the drift guard**

Create `scripts/check-graphloop-sync.mjs`:

```js
// CI guard: regenerates the vendored copy into a temp dir and fails if it
// differs from the committed supabase/functions/_shared/graphloop. Run this
// whenever src/lib/graphloop changes.
import { readdirSync, readFileSync, mkdtempSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { syncInto } from "./sync-graphloop.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const committed = join(root, "supabase/functions/_shared/graphloop");
const temp = mkdtempSync(join(tmpdir(), "graphloop-"));
syncInto(temp);

let drift = false;
for (const f of readdirSync(temp)) {
  const a = readFileSync(join(temp, f), "utf8");
  const b = readFileSync(join(committed, f), "utf8");
  if (a !== b) { drift = true; console.error(`DRIFT: ${f}`); }
}
if (drift) { console.error("Run: node scripts/sync-graphloop.mjs && commit"); process.exit(1); }
console.log("graphloop vendored copy is in sync");
```

- [ ] **Step 5: Run the drift guard to verify it passes**

Run: `node scripts/check-graphloop-sync.mjs`
Expected: prints `graphloop vendored copy is in sync`, exit 0.

- [ ] **Step 6: Write the import map**

Create `supabase/functions/retrieve-memory/deno.json` (versions pinned from package-lock.json):

```json
{
  "imports": {
    "@orama/orama": "https://esm.sh/@orama/orama@3.1.18",
    "graphology": "https://esm.sh/graphology@0.26.0",
    "graphology-communities-louvain": "https://esm.sh/graphology-communities-louvain@2.0.2"
  }
}
```

- [ ] **Step 7: Commit**

```bash
git add scripts/sync-graphloop.mjs scripts/check-graphloop-sync.mjs supabase/functions/_shared/graphloop supabase/functions/retrieve-memory/deno.json src/lib/graphloop/types.ts
git commit -m "build: vendor graphloop retrieval subset for the Deno edge function"
```

---

## Task 2: Edge function — context builder (TDD)

The function must return context built from **entities + relations only**. This is the privacy-critical unit; test it in isolation first. It lives in its own side-effect-free module (`context.ts`) so the test never imports `index.ts` and never starts the `serve()` HTTP listener.

**Files:**
- Create: `supabase/functions/retrieve-memory/context.ts`
- Create: `supabase/functions/retrieve-memory/context.test.ts`

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/retrieve-memory/context.test.ts`:

```ts
import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildContext } from "./context.ts";
import type { RetrievalResult } from "../_shared/graphloop/types.ts";

Deno.test("buildContext emits entities + relations, never a Sources section", () => {
  const result: RetrievalResult = {
    entities: [
      { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 3, firstSeen: "2026-01-01T00:00:00Z", lastSeen: "2026-01-02T00:00:00Z", description: "a friend" },
      { id: "atlas", name: "Atlas", type: "project", metadata: {}, mentions: 2, firstSeen: "2026-01-01T00:00:00Z", lastSeen: "2026-01-02T00:00:00Z" },
    ],
    relations: [
      { id: "r1", source: "maya", target: "atlas", label: "works_on", metadata: {}, createdAt: "2026-01-02T00:00:00Z" },
    ],
    entries: [
      { id: "e1", text: "SENTINEL_SECRET maya is on atlas", createdAt: "2026-01-02T00:00:00Z", entityIds: ["maya", "atlas"], relationIds: ["r1"] },
    ],
    seeds: ["maya"],
    context: "ignored — packer output is not trusted",
  };
  const ctx = buildContext(result);
  assert(ctx.includes("## Entities"));
  assert(ctx.includes("Maya (person)"));
  assert(ctx.includes("Maya --works_on--> Atlas"));
  assert(!ctx.includes("## Sources"), "must not include a Sources section");
  assert(!ctx.includes("SENTINEL_SECRET"), "must not include verbatim entry text");
});

Deno.test("buildContext falls back to the (source-free) global context when no entities", () => {
  const result: RetrievalResult = {
    entities: [], relations: [], entries: [], seeds: [],
    communities: [{ id: 0, label: "area", entityIds: ["a"], size: 1, topEntities: ["A"] }],
    context: "## Relevant areas of memory\n- area (1 entities): A",
  };
  const ctx = buildContext(result);
  assertEquals(ctx, "## Relevant areas of memory\n- area (1 entities): A");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `deno test --import-map supabase/functions/retrieve-memory/deno.json supabase/functions/retrieve-memory/context.test.ts`
Expected: FAIL — module `./context.ts` not found.

- [ ] **Step 3: Write the minimal implementation**

Create `supabase/functions/retrieve-memory/context.ts`:

```ts
import type { RetrievalResult } from "../_shared/graphloop/types.ts";

/**
 * Build the LLM-facing context from a RetrievalResult using entities + relations
 * ONLY. graphloop's own packContext appends verbatim journal entries as a
 * "## Sources" section; we never emit that. When there are no seed entities,
 * retrieve() returns a source-free global/community context which we pass through.
 */
export function buildContext(result: RetrievalResult): string {
  if (result.entities.length === 0) return result.context; // global/empty: source-free by construction
  const byId = new Map(result.entities.map((e) => [e.id, e]));
  const out: string[] = ["## Entities"];
  for (const e of result.entities) {
    const desc = e.description ? `: ${e.description}` : "";
    out.push(`- ${e.name} (${e.type})${desc} [mentions: ${e.mentions}]`);
  }
  if (result.relations.length) {
    out.push("## Relations");
    for (const r of result.relations) {
      const s = byId.get(r.source)?.name ?? r.source;
      const t = byId.get(r.target)?.name ?? r.target;
      out.push(`- ${s} --${r.label}--> ${t}`);
    }
  }
  return out.join("\n");
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `deno test --import-map supabase/functions/retrieve-memory/deno.json supabase/functions/retrieve-memory/context.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/retrieve-memory/context.ts supabase/functions/retrieve-memory/context.test.ts
git commit -m "feat: source-free context builder for retrieve-memory edge function"
```

---

## Task 3: Edge function — HTTP handler (auth, ownership, caps, retrieval)

**Files:**
- Modify: `supabase/functions/retrieve-memory/index.ts`
- Modify: `supabase/config.toml`

- [ ] **Step 1: Create `index.ts` with the imports and constants**

Create `supabase/functions/retrieve-memory/index.ts` (imports `buildContext` from the side-effect-free `context.ts`):

```ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { retrieve } from "../_shared/graphloop/retrieve.ts";
import { SearchIndex } from "../_shared/graphloop/search-index.ts";
import { buildCommunities } from "../_shared/graphloop/communities.ts";
import type { GraphState } from "../_shared/graphloop/types.ts";
import { buildContext } from "./context.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const MAX_BODY_BYTES = 1_000_000;
const MAX_ENTITIES = 2000;
const MAX_RELATIONS = 4000;
const MAX_ENTRIES = 2000;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

// Non-sensitive SRE telemetry — counts, latency, empty-flag, a short query hash.
// NEVER content (spec §7). Emitted to the function log for ops visibility.
function logTelemetry(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ fn: "retrieve-memory", ...fields }));
}

async function queryHash(q: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(q));
  return [...new Uint8Array(digest)].slice(0, 4).map((b) => b.toString(16).padStart(2, "0")).join("");
}
```

- [ ] **Step 2: Append the `serve` handler at the bottom of `index.ts`**

```ts
serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const startedAt = Date.now();
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json(401, { error: "missing authorization" });
    const supa = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: userErr } = await supa.auth.getUser();
    if (userErr || !user) return json(401, { error: "invalid session" });

    const body = JSON.parse(raw) as {
      query?: string;
      notebookId?: string;
      state?: { entities?: Record<string, unknown>; relations?: Record<string, unknown>; entries?: unknown[] };
    };

    const notebookId = body.notebookId;
    if (!notebookId) return json(400, { error: "notebookId required" });
    const { data: nb, error: nbErr } = await supa
      .from("notebooks").select("id").eq("id", notebookId).single();
    if (nbErr || !nb) return json(404, { error: "notebook not found" });

    const query = (body.query ?? "").trim();
    const entities = body.state?.entities ?? {};
    const relations = body.state?.relations ?? {};
    const entries = body.state?.entries ?? [];
    if (
      Object.keys(entities).length > MAX_ENTITIES ||
      Object.keys(relations).length > MAX_RELATIONS ||
      entries.length > MAX_ENTRIES
    ) {
      return json(413, { error: "graph too large" });
    }
    if (!query || Object.keys(entities).length === 0) return json(200, { context: "" });

    const g = { entities, relations, entries } as unknown as GraphState;
    const index = new SearchIndex();
    await index.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    const result = await retrieve(g, query, { mode: "lexical" }, { index, communities });
    const context = buildContext(result);
    logTelemetry({
      ok: true,
      entityCount: result.entities.length,
      relationCount: result.relations.length,
      seedCount: result.seeds.length,
      emptyContext: context.length === 0,
      latencyMs: Date.now() - startedAt,
      qHash: await queryHash(query),
    });
    return json(200, { context });
  } catch (e) {
    // Never log the request body or context (spec §7). Counts / error name only.
    logTelemetry({
      ok: false,
      error: e instanceof Error ? e.name : "unknown",
      latencyMs: Date.now() - startedAt,
    });
    return json(500, { error: "retrieve failed" });
  }
});
```

- [ ] **Step 3: Register the function in `supabase/config.toml`**

Add after the `[functions.speak-agent]` block:

```toml
[functions.retrieve-memory]
verify_jwt = true
```

- [ ] **Step 4: Typecheck the function**

Run: `deno check --import-map supabase/functions/retrieve-memory/deno.json supabase/functions/retrieve-memory/index.ts`
Expected: no type errors (downloads esm.sh deps on first run).

- [ ] **Step 4b: Generate the dependency lock**

Run: `deno cache --import-map supabase/functions/retrieve-memory/deno.json --lock supabase/functions/retrieve-memory/deno.lock supabase/functions/retrieve-memory/index.ts`
Expected: writes `supabase/functions/retrieve-memory/deno.lock` pinning the full esm.sh dependency graph (Orama + graphology transitive deps). Commit it so the deployed bundle resolves deterministically, not against floating CDN versions (spec §6).

- [ ] **Step 5: Re-run the context-builder tests (no regression)**

Run: `deno test --import-map supabase/functions/retrieve-memory/deno.json supabase/functions/retrieve-memory/context.test.ts`
Expected: PASS (2 tests) — `context.ts` is unchanged; this confirms the split is clean.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/retrieve-memory/index.ts supabase/config.toml supabase/functions/retrieve-memory/deno.lock
git commit -m "feat: retrieve-memory handler with auth, ownership, input caps, telemetry"
```

---

## Task 3b: Server-side rate limiting (DB-backed fixed window)

The Flutter over-call guardrails only constrain the honest app. A user with a valid JWT can call the function directly and bypass them, so the function must check a **durable, shared** counter before the expensive retrieval. Two fixed-window counters in Postgres — one per **user**, one per **notebook/session** — are bumped via a single RPC after auth + ownership and before retrieval (ownership is a cheap indexed lookup; the graphloop work is what we gate). The counter table is **operational state, not user data**: clients get no direct access (RLS enabled with no policy + revoked grants), and only a `SECURITY DEFINER` RPC may touch it — so a user cannot reset or inflate their own counter.

**Files:**
- Create: `supabase/migrations/20260626000000_retrieve_rate_limits.sql`
- Modify: `supabase/functions/retrieve-memory/index.ts`

- [ ] **Step 1: Write the migration (table + RLS + bump RPC)**

Create `supabase/migrations/20260626000000_retrieve_rate_limits.sql`:

```sql
-- Fixed-window rate limiting for the retrieve-memory edge function.
-- Operational state, NOT user data: clients get zero direct access. Rows are
-- keyed by an opaque scope string ('user:<uid>' or 'notebook:<id>') and may be
-- touched only by the SECURITY DEFINER RPC below.
create table public.retrieve_rate_limits (
  scope        text not null,
  window_start timestamptz not null,
  count        int not null default 0,
  primary key (scope, window_start)
);

-- RLS on + no policy = no direct row access for anon/authenticated. The revokes
-- below are belt-and-suspenders against PostgREST exposure.
alter table public.retrieve_rate_limits enable row level security;
revoke all on table public.retrieve_rate_limits from anon, authenticated;

-- Atomically bump the caller's per-user AND per-notebook counters for the
-- current window and report whether BOTH are within their limits.
--
-- SELF-CONTAINED & TAMPER-PROOF — the function takes ONLY p_notebook_id; the
-- window and limits are hardcoded in the DB so a direct RPC caller (the RPC is
-- granted to `authenticated`) cannot widen its own limits. Ownership is verified
-- INSIDE the function, before any counter is touched, so a caller cannot inflate
-- the notebook:<id> counter of a notebook they do not own (cross-notebook
-- griefing). The user:<uid> scope derives from auth.uid(), never a parameter, so
-- it can only ever bump the caller's own user counter.
--
-- SECURITY DEFINER (runs as owner, bypassing RLS) so the caller cannot mutate
-- the counters directly. Fixed search_path is mandatory for DEFINER safety.
-- auth.uid() reads the request JWT claim and works under DEFINER.
create or replace function public.bump_retrieve_rate(p_notebook_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_window_seconds  constant int := 60;
  v_user_limit      constant int := 30;
  v_notebook_limit  constant int := 20;
  v_window timestamptz := to_timestamp(
    floor(extract(epoch from now()) / v_window_seconds) * v_window_seconds
  );
  v_user_count int;
  v_nb_count int;
begin
  if v_uid is null then
    return false;
  end if;

  -- Never bump a counter for a notebook the caller does not own.
  if not exists (
    select 1 from public.notebooks where id = p_notebook_id and user_id = v_uid
  ) then
    return false;
  end if;

  insert into public.retrieve_rate_limits (scope, window_start, count)
    values ('user:' || v_uid::text, v_window, 1)
  on conflict (scope, window_start)
    do update set count = retrieve_rate_limits.count + 1
  returning count into v_user_count;

  insert into public.retrieve_rate_limits (scope, window_start, count)
    values ('notebook:' || p_notebook_id::text, v_window, 1)
  on conflict (scope, window_start)
    do update set count = retrieve_rate_limits.count + 1
  returning count into v_nb_count;

  return v_user_count <= v_user_limit and v_nb_count <= v_notebook_limit;
end;
$$;

-- Execute granted ONLY to authenticated; revoke the default public grant.
revoke all on function public.bump_retrieve_rate(uuid) from public, anon;
grant execute on function public.bump_retrieve_rate(uuid) to authenticated;
```

- [ ] **Step 2: Apply the migration locally and verify it succeeds**

Run: `supabase migration up` (or `supabase db reset` for a clean apply).
Expected: applies without error; `\d public.retrieve_rate_limits` shows the table with RLS enabled and **no** policies, and `\df public.bump_retrieve_rate` shows it as `security definer`.

- [ ] **Step 3: Add the rate check to the handler**

In `supabase/functions/retrieve-memory/index.ts`, insert the rate check **after** the notebook-ownership block (`if (nbErr || !nb) return json(404, …)`) and **before** `const query = (body.query ?? "").trim();`. Ownership is a cheap indexed lookup, so this still gates all expensive retrieval work, and `notebookId` is now in scope for the per-notebook counter:

```ts
    // Durable, per-user AND per-notebook rate limit, enforced server-side so a
    // direct JWT caller cannot bypass it the way the Flutter guardrails allow.
    // Window + limits live in the DB function; the client controls nothing, and
    // the function verifies notebook ownership itself.
    const { data: allowed, error: rateErr } = await supa.rpc("bump_retrieve_rate", {
      p_notebook_id: notebookId,
    });
    if (rateErr) {
      logTelemetry({ ok: false, error: "rate_check_failed", latencyMs: Date.now() - startedAt });
      return json(500, { error: "rate check failed" });
    }
    if (allowed === false) {
      logTelemetry({ ok: false, error: "rate_limited", latencyMs: Date.now() - startedAt });
      return json(429, { error: "rate limit exceeded" });
    }
```

- [ ] **Step 4: Typecheck**

Run: `deno check --import-map supabase/functions/retrieve-memory/deno.json supabase/functions/retrieve-memory/index.ts`
Expected: no type errors.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260626000000_retrieve_rate_limits.sql supabase/functions/retrieve-memory/index.ts
git commit -m "feat: per-user server-side rate limit for retrieve-memory"
```

> **Cleanup note (minor follow-up, not blocking):** old window rows accumulate at roughly one row per active user and one per active notebook per minute. A periodic `delete from retrieve_rate_limits where window_start < now() - interval '1 day'` (pg_cron or a scheduled function) keeps the table small. Out of scope for Phase 1.

---

## Task 4: Deploy & smoke-test the edge function (manual — requires correct CLI account)

No TDD — this validates the deployed bundle (esm.sh resolution + Orama/graphology in Deno surface only at cold-start, spec §6) and the live DB migration.

**Files:** none. **All steps mutate the LIVE backend — run only against the app's real project.**

> ### ⛔ DEPLOY PREFLIGHT (MANDATORY — do not skip)
> The deploy target **must** equal the app's project ref everywhere:
> ```text
> supabase/config.toml  project_id          = bjoevzvsdlhlcjywpyfx
> .env  VITE_SUPABASE_PROJECT_ID / SUPABASE_URL  → bjoevzvsdlhlcjywpyfx
> Flutter app SUPABASE_URL                  → bjoevzvsdlhlcjywpyfx
> ```
> **Do not run any migration/function deploy unless `supabase projects list` includes `bjoevzvsdlhlcjywpyfx`.** As of 2026-06-26 the logged-in CLI account only saw `giyjrvixpbfnourkpsen` ("AI-journal"); deploying from that session would update the WRONG project — the deploy would look "successful" but the app (still calling `bjoevzvsdlhlcjywpyfx`) would see no change, and Tasks 4/8 would fail in the real app. If the CLI only sees another project, **STOP** and treat Tasks 4/8 as BLOCKED, or treat `giyjrvixpbfnourkpsen` as explicit *staging* (separate staging env values, never called live/prod).

- [ ] **Step 0: Preflight — make CLI access match the app project**

```bash
supabase projects list   # must include bjoevzvsdlhlcjywpyfx
# if it does not, switch to an account that has access:
supabase logout && supabase login && supabase projects list
supabase link --project-ref bjoevzvsdlhlcjywpyfx
```
Proceed only once `bjoevzvsdlhlcjywpyfx` is visible AND linked.

- [ ] **Step 1: Apply the rate-limit migration to the live DB**

```bash
supabase db push --dry-run    # review the SQL that will run
supabase db push              # applies 20260626000000_retrieve_rate_limits.sql
```
Expected: the `retrieve_rate_limits` table + `bump_retrieve_rate(uuid)` function are created. (This is the live-DB equivalent of Task 3b Step 2, which could not run locally without Docker.)

- [ ] **Step 2: Deploy the function**

Run: `supabase functions deploy retrieve-memory --project-ref bjoevzvsdlhlcjywpyfx --import-map supabase/functions/retrieve-memory/deno.json`
Expected: deploy succeeds; no "module not found" for `@orama/orama` / `graphology` / `graphology-communities-louvain`.

> `--project-ref` pins the target explicitly (defense against the account/project mismatch above). `--import-map` is **required**: `supabase functions deploy` does not implicitly use the function-dir `deno.json` for resolution (verified against Supabase CLI 2.75.0). Without it the deployed bundle fails to resolve the bare specifiers at cold-start.

- [ ] **Step 3: Capture a real user JWT**

Set the project values, then mint an access token. The anon key alone is NOT a user JWT — the function calls `auth.getUser()`. Either sign in an existing user (password grant) or sign up a throwaway test user:

```bash
export SUPABASE_URL="https://bjoevzvsdlhlcjywpyfx.supabase.co"
export ANON="<anon/publishable key from .env>"
# existing user (password grant):
JWT=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"email":"<user-email>","password":"<password>"}' | jq -r .access_token)
# OR throwaway test user (writes to live auth.users — clean it up after):
#   POST "$SUPABASE_URL/auth/v1/signup" with the same headers/body → returns access_token
export JWT
```
You also need an **owned notebook id** for that user (query `notebooks` for `user_id = <that user>`, or create one).

- [ ] **Step 4: Smoke-test a valid call**

Run:
```bash
curl -s -X POST "$SUPABASE_URL/functions/v1/retrieve-memory" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"query":"atlas","notebookId":"<an-owned-notebook-id>","state":{"entities":{"atlas":{"id":"atlas","name":"Atlas","type":"project","metadata":{},"mentions":2,"firstSeen":"2026-01-01T00:00:00Z","lastSeen":"2026-01-02T00:00:00Z"}},"relations":{},"entries":[]}}'
```
Expected: `{"context":"## Entities\n- Atlas (project) [mentions: 2]"}`.

- [ ] **Step 5: Verify the guards**

Run the same curl with (a) no `notebookId` → expect `400`; (b) a notebook id the user doesn't own → expect `404`; (c) no `Authorization` header → expect `401`; (d) the same valid call (same `notebookId`) in a tight loop more than the per-notebook limit (20, hardcoded in the DB function) times within a minute → calls past the limit return `429`.

Example for (d):
```bash
for i in $(seq 1 35); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$SUPABASE_URL/functions/v1/retrieve-memory" \
    -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d '{"query":"atlas","notebookId":"<owned-id>","state":{"entities":{},"relations":{},"entries":[]}}'
done
```
Expected: the first 20 print `200`, the remainder print `429` (the per-notebook limit of 20 trips before the per-user limit of 30).

- [ ] **Step 5b: Security — direct-RPC griefing is blocked**

Call the rate-limit RPC directly (bypassing the edge function) with a notebook UUID the JWT's user does NOT own:

```bash
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/bump_retrieve_rate" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d '{"p_notebook_id":"<a-notebook-uuid-NOT-owned-by-this-user>"}'
```
Expected: response body `false`, and **no** `notebook:<that-id>` row is created (verify with `select * from retrieve_rate_limits where scope = 'notebook:<that-id>';` → 0 rows). Confirms a caller cannot inflate another notebook's counter.

- [ ] **Step 5: Commit (notes only, if any config changed)**

If deploy required no file changes, skip. Otherwise commit the change with `git commit -m "chore: retrieve-memory deploy config"`.

---

## Task 5: Dart service — `stateToGraphloop` serializer (TDD)

The camelCase serializer is the bug-prone unit (Dart models emit snake_case via `FieldRename.snake`). Test it first.

**Files:**
- Create: `lib/services/retrieve_memory_service.dart`
- Create: `test/retrieve_memory_service_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/retrieve_memory_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/retrieve_memory_service.dart';

void main() {
  final now = DateTime.utc(2026, 6, 13, 9);

  test('stateToGraphloop emits graphloop camelCase keys, not snake_case', () {
    final state = JournalState(
      entries: [
        JournalEntry(
          id: 'e1',
          text: 'Maya works on Atlas.',
          createdAt: now,
          entityIds: const ['maya', 'atlas'],
          relationIds: const ['r1'],
        ),
      ],
      entities: {
        'maya': Entity(
          id: 'maya',
          name: 'Maya',
          type: EntityType.person,
          metadata: const {},
          mentions: 2,
          firstSeen: now,
          lastSeen: now,
          questions: const ['Who is Maya?'],
        ),
      },
      relations: {
        'r1': Relation(
          id: 'r1',
          source: 'maya',
          target: 'atlas',
          label: 'works_on',
          metadata: const {},
          createdAt: now,
          supersededAt: now,
        ),
      },
      followUps: const [],
    );

    final out = stateToGraphloop(state);

    // Entities keyed by id; camelCase timestamp fields.
    final maya = (out['entities'] as Map)['maya'] as Map;
    expect(maya['firstSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya['lastSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya.containsKey('first_seen'), isFalse);
    expect(maya['type'], 'person');

    // Relations: camelCase createdAt / supersededAt.
    final r1 = (out['relations'] as Map)['r1'] as Map;
    expect(r1['createdAt'], '2026-06-13T09:00:00.000Z');
    expect(r1['supersededAt'], '2026-06-13T09:00:00.000Z');
    expect(r1.containsKey('superseded_at'), isFalse);

    // Entries: list with camelCase entityIds / relationIds.
    final e1 = (out['entries'] as List).first as Map;
    expect(e1['entityIds'], ['maya', 'atlas']);
    expect(e1['relationIds'], ['r1']);
    expect(e1.containsKey('entity_ids'), isFalse);

    // followUps dropped.
    expect(out.containsKey('followUps'), isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/retrieve_memory_service_test.dart`
Expected: FAIL — `stateToGraphloop` / `retrieve_memory_service.dart` not found.

- [ ] **Step 3: Write the serializer + service**

Create `lib/services/retrieve_memory_service.dart`:

```dart
import 'dart:developer' as developer;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';

String _iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, dynamic> _entity(Entity e) => {
      'id': e.id,
      'name': e.name,
      'type': e.type.name,
      if (e.description != null) 'description': e.description,
      'metadata': e.metadata,
      'mentions': e.mentions,
      'firstSeen': _iso(e.firstSeen),
      'lastSeen': _iso(e.lastSeen),
      if (e.questions != null) 'questions': e.questions,
    };

Map<String, dynamic> _relation(Relation r) => {
      'id': r.id,
      'source': r.source,
      'target': r.target,
      'label': r.label,
      'metadata': r.metadata,
      'createdAt': _iso(r.createdAt),
      if (r.supersededAt != null) 'supersededAt': _iso(r.supersededAt!),
    };

Map<String, dynamic> _entry(JournalEntry en) => {
      'id': en.id,
      'text': en.text,
      'createdAt': _iso(en.createdAt),
      'entityIds': en.entityIds,
      'relationIds': en.relationIds,
    };

/// Serialize JournalState into graphloop's GraphState shape (camelCase keys,
/// ISO-8601 UTC timestamps). NOT the Dart models' snake_case toJson() — the
/// edge function's retrieve() reads camelCase (lastSeen, entityIds, …).
/// followUps / askedQuestions are intentionally dropped (retrieval never uses
/// them), matching the web app's toGraphState.
Map<String, dynamic> stateToGraphloop(JournalState state) => {
      'entities': {
        for (final e in state.entities.values) e.id: _entity(e),
      },
      'relations': {
        for (final r in state.relations.values) r.id: _relation(r),
      },
      'entries': state.entries.map(_entry).toList(),
    };

/// Calls the retrieve-memory edge function. Fail-closed: any error returns "".
class RetrieveMemoryService {
  final SupabaseClient _client;

  RetrieveMemoryService(this._client);

  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async {
    final q = query.trim();
    if (q.length < 2) return '';
    final startedAt = DateTime.now();

    // Non-sensitive telemetry: outcome + counts only, never query/context text.
    void emit(String outcome, int contextLength) => developer.log(
          'outcome=$outcome qLen=${q.length} contextLen=$contextLength '
          'latencyMs=${DateTime.now().difference(startedAt).inMilliseconds}',
          name: 'lumen.memory',
        );

    try {
      final res = await _client.functions.invoke(
        'retrieve-memory',
        body: {
          'query': q,
          'notebookId': notebookId,
          'state': stateToGraphloop(state),
        },
      );
      final data = res.data;
      if (data is Map && data['context'] is String) {
        final context = data['context'] as String;
        emit(context.isEmpty ? 'empty' : 'ok', context.length);
        return context;
      }
      emit('malformed', 0);
      return '';
    } catch (_) {
      emit('error', 0);
      return '';
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/retrieve_memory_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/retrieve_memory_service.dart test/retrieve_memory_service_test.dart
git commit -m "feat: RetrieveMemoryService with camelCase graphloop serializer"
```

---

## Task 6: Port the `get_relevant_memory` prompt block (source-free wording)

The web prompt promises "the user's own words (sources)" — Flutter drops sources, so the ported block must NOT promise verbatim sources.

**Files:**
- Modify: `lib/logic/conversation_policy.dart`

- [ ] **Step 1: Insert the tool block into the system instruction**

In `lib/logic/conversation_policy.dart`, find the anchor (end of the `get_graph_summary` fields list, just before the picking-your-question section):

```dart
- sessionElapsedMin: how long the session has been running.

HOW TO PICK YOUR NEXT QUESTION (preference order):
```

Replace it with (inserts the second-tool block between them):

```dart
- sessionElapsedMin: how long the session has been running.

YOUR SECOND PRIVATE TOOL — get_relevant_memory({ query }):
Where get_graph_summary tells you what to ASK next, get_relevant_memory tells you what the user has already SAID that's relevant right now. It returns a focused packet: related entities and how they connect. Call it when the user refers back to something from earlier ("that thing with my sister", "the project I mentioned"), or when grounding your reply in what they actually said would make you sound like you remember. Pass a few words as the query (a name, a topic, a phrase). The result is for YOUR planning only — never read it aloud, never mention memory, the graph, or any field. If a later turn corrected an earlier fact, do not reuse the old version. Let it make your reply feel continuous, not retrieved.

HOW TO PICK YOUR NEXT QUESTION (preference order):
```

- [ ] **Step 2: Verify the file still compiles**

Run: `flutter analyze lib/logic/conversation_policy.dart`
Expected: "No issues found!" (the change is inside an existing raw string literal).

- [ ] **Step 3: Commit**

```bash
git add lib/logic/conversation_policy.dart
git commit -m "feat: add get_relevant_memory guidance to the live system prompt"
```

---

## Task 7: Register the tool & wire the handler

**Files:**
- Modify: `lib/providers/journal_provider.dart`

- [ ] **Step 1: Add the import**

At the top of `lib/providers/journal_provider.dart`, add (alongside the other service imports):

```dart
import '../services/retrieve_memory_service.dart';
```

- [ ] **Step 2: Register the `get_relevant_memory` declaration**

In the `GeminiLiveClient(... tools: [...])` list, the `function_declarations` array currently holds only `get_graph_summary`. Add a second entry directly after it:

```dart
              {
                'name': 'get_graph_summary',
                'description':
                    'Returns the current knowledge graph state and agenda for the agent to plan its next question.',
                'parameters': {'type': 'object', 'properties': {}},
              },
              {
                'name': 'get_relevant_memory',
                'description':
                    'Retrieve past memory relevant to a query: related entities and how they connect. Use when the user references something from earlier, or when grounding your reply in prior context would help. Distinct from get_graph_summary. For planning only — never read aloud.',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'query': {
                      'type': 'string',
                      'description':
                          'A few words to recall: a name, a topic, or a phrase.',
                    },
                  },
                  'required': ['query'],
                },
              },
```

- [ ] **Step 3: Add over-call guardrail fields**

Add these instance fields to the notifier class (near the other private session fields such as `_lastTranscript` / `_sessionStartedAt`):

```dart
  String? _lastMemoryQuery;
  int _memoryCallsThisTurn = 0;
  static const _maxMemoryCallsPerTurn = 3;
```

- [ ] **Step 4: Reset the per-turn counter on turn complete**

The client wires `..onTurnComplete = () {}`. Replace it with:

```dart
        ..onTurnComplete = () {
          _memoryCallsThisTurn = 0;
          _lastMemoryQuery = null;
        }
```

Resetting **both** is load-bearing: `_lastMemoryQuery` dedups only *immediate* repeat calls within a single planning turn. Without the reset, a legitimate later turn asking about the same entity/topic would be suppressed for the rest of the session (returning empty context despite a real recall need).

- [ ] **Step 5: Route the tool call**

Replace the existing `onToolCall` handler:

```dart
        ..onToolCall = (name, args) async {
          if (name == 'get_graph_summary') return _buildGraphSummary();
          return const {};
        }
```

with:

```dart
        ..onToolCall = (name, args) async {
          if (name == 'get_graph_summary') return _buildGraphSummary();
          if (name == 'get_relevant_memory') return _retrieveMemory(args);
          return const {};
        }
```

- [ ] **Step 6: Add the `_retrieveMemory` method**

Add near `_buildGraphSummary` in the notifier:

```dart
  Future<Map<String, dynamic>> _retrieveMemory(Map<String, dynamic> args) async {
    final notebookId = _activeNotebookId;
    final query = (args['query'] as String?)?.trim() ?? '';
    // Over-call guardrails: tiny query, identical repeat, per-turn cap.
    if (notebookId == null ||
        query.length < 2 ||
        query == _lastMemoryQuery ||
        _memoryCallsThisTurn >= _maxMemoryCallsPerTurn) {
      return const {'context': ''};
    }
    _memoryCallsThisTurn++;
    _lastMemoryQuery = query;
    final service = RetrieveMemoryService(ref.read(supabaseClientProvider));
    final context = await service.retrieve(
      query: query,
      notebookId: notebookId,
      state: state,
    );
    return {'context': context};
  }
```

- [ ] **Step 7: Add the provider import for `supabaseClientProvider`**

Confirm `supabase_provider.dart` is imported (it exports `supabaseClientProvider`). If not already imported, add:

```dart
import 'supabase_provider.dart';
```

- [ ] **Step 8: Analyze**

Run: `flutter analyze lib/providers/journal_provider.dart`
Expected: "No issues found!"

- [ ] **Step 9: Run the full Dart test suite (no regressions)**

Run: `flutter test`
Expected: all tests pass, including `test/retrieve_memory_service_test.dart`.

- [ ] **Step 10: Commit**

```bash
git add lib/providers/journal_provider.dart
git commit -m "feat: wire get_relevant_memory tool into the live session"
```

---

## Task 8: End-to-end verification (manual)

**Files:** none.

- [ ] **Step 1: Run the app against the deployed function**

Launch the Flutter app, sign in, start a voice session. Mention a few entities (e.g. "I worked on Atlas with Maya today").

- [ ] **Step 2: Trigger recall within the session**

Later in the same session, refer back: "what was that project again?" Confirm the agent grounds its reply in Atlas/Maya without naming the tool, the graph, or quoting any entry text.

- [ ] **Step 3: Confirm the no-sources egress**

In the Supabase function logs (or a proxy), confirm responses contain `## Entities` / `## Relations` and never `## Sources` or raw entry text. (Logs must not contain request bodies — spec §7.)

- [ ] **Step 4: Confirm fail-closed**

Temporarily point the app at a non-existent function name or disable the function; confirm the session continues (no crash) and the agent simply doesn't recall — `retrieve()` returns `''`.

- [ ] **Step 5: Confirm within-session scope expectation**

Verify that recall only surfaces entities from the current session's notebook (Phase 1 = within-session). Cross-day recall is expected NOT to work (spec §10).

---

## Self-Review Notes (completed by plan author)

- **Spec coverage:** §5.1 edge function → Tasks 2, 3, 3b; §5.2 service/serializer/guardrails/fail-closed → Tasks 5, 7; §5.3 prompt + wiring → Tasks 6, 7; §6 Deno resolution (4 specifiers, extensionless imports, embed stub) + pinned deploy import-map + committed lock → Tasks 1, 3 (Step 4b), 4 (Step 1); §7 no-sources egress + no body/context logging → Tasks 2, 3, 8; §8 input caps → Task 3, over-call guardrails (per-turn, reset on turn complete) → Task 7, **server-side rate limit** (per-user + per-notebook; self-contained SECURITY DEFINER RPC with internal ownership check + DB-fixed window/limits, safe to call directly) → Task 3b, **fail-closed telemetry** (structured non-sensitive logs, edge + Dart) → Tasks 3, 5; §11 prerequisite → noted, out of scope; §12 tests → Tasks 2, 5, 8 + rate-limit/429 smoke → Task 4; §13 gate → covered across tasks.
- **Type consistency:** `buildContext` (Tasks 2–3), `stateToGraphloop` + `RetrieveMemoryService.retrieve` (Tasks 5, 7), `_retrieveMemory` (Task 7) names are consistent across references. Wire key `notebookId` used uniformly. Function returns `{ context }`; Dart reads `data['context']`.
- **No placeholders:** every code step shows complete code; every run step shows the command + expected output.

# Lumen × GraphLoop Read-Side Memory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GraphLoop's read-side GraphRAG retrieval to Lumen as an additive memory layer beside the untouched write path, exposed to the voice agent through a new `get_relevant_memory({ query })` tool.

**Architecture:** Vendor GraphLoop's pure retrieval modules into `src/lib/graphloop/` (verbatim copies, trimmed types), add one hand-written adapter `src/lib/journal-memory.ts` that maps Lumen's in-memory `JournalState → GraphState` and calls `retrieve()`. Retrieval is lexical BM25 (Orama) + k-hop graph expansion + Louvain community fallback — no LLM calls, runs client-side. A prerequisite Supabase schema change makes entry→entity/relation provenance survive reloads.

**Tech Stack:** TypeScript, TanStack Start (Vite 7, React 19), `@orama/orama`, `graphology` + `graphology-communities-louvain`, Vitest 3, Supabase (Postgres), Gemini Live.

**Spec:** [docs/superpowers/specs/2026-06-17-lumen-graphloop-memory-design.md](../specs/2026-06-17-lumen-graphloop-memory-design.md)

---

## Working Assumptions (Codex: verify these before executing)

These assumptions shaped the plan. If any is false in the current tree, stop and reconcile before proceeding.

1. **Target is the web app** (`echo-insights`, TanStack Start), not the Flutter iOS port. GraphLoop is a TS/JS library; Dart parity is out of scope.
2. **GraphLoop source is a point-in-time snapshot** of `github.com/Hostileoracle0606/graphloop` `main` as read on 2026-06-17 (modules: `types.ts`, `noise.ts`, `graph-ops.ts`, `search-index.ts`, `communities.ts`, `embed.ts`, `retrieve.ts`). Full file contents are inlined in this plan, so repo access is **not** required. Future upstream changes are re-synced manually.
3. **Type compatibility is exact.** Lumen's `Entity`, `Relation`, `JournalEntry` ([src/lib/journal-types.ts](../../../src/lib/journal-types.ts)) are field-for-field identical to GraphLoop's `Entity`, `Relation`, `GraphEntry`. Therefore `toGraphState` is a field pick (`{ entities, relations, entries }`), not a transform, and TypeScript structural typing accepts Lumen objects where vendored types are expected. **If the shapes have diverged, the adapter needs a real mapping and this plan must be revised.**
4. **Retrieval runs client-side** in the live-session route (`src/routes/index.tsx` is a client component using `window`/`localStorage`). Orama and graphology are browser-safe. No edge function is added.
5. **Lumen has no test runner today** (no `vitest`, no `test` script). Task 0 introduces Vitest via a standalone `vitest.config.ts` (environment `node`, `vite-tsconfig-paths` for the `@/` alias) so the existing `@lovable.dev/vite-tanstack-config` wrapper in `vite.config.ts` is left untouched. Tests are co-located under `src/**` so they never scan the Flutter `test/` directory.
6. **The Gemini Live hook awaits async tool handlers.** `onToolCall?: (call) => unknown | Promise<unknown>` and its resolved value is sent back ([src/hooks/use-gemini-live.ts:46-50](../../../src/hooks/use-gemini-live.ts)). So the recall handler can be `async`.
7. **Gemini function-declaration parameter types are uppercase** (`"OBJECT"`, `"STRING"`), matching the existing `get_graph_summary` declaration ([src/routes/index.tsx:766-776](../../../src/routes/index.tsx)).
8. **Supabase migrations** are applied through the project's existing workflow (a new timestamped SQL file in `supabase/migrations/`). Because `saveState` is snapshot-replace (delete + reinsert), **no data backfill** is needed; existing rows default to empty provenance arrays and gain real values on next save.
9. **Phase 1 is lexical + community fallback only.** `embeddingModel` is never configured, so `embed.ts` is retained-but-dormant (kept for upstream parity and the deferred hybrid step). Retrieval performs zero network/LLM calls.
10. **Package manager:** the repo carries both `bun.lockb` and `package-lock.json`. Commands below use `npm`/`npx`; substitute `bun`/`bunx` if bun is canonical in your environment. Do not commit a second lockfile churn beyond the dependencies this plan adds.
11. **`graphology-communities-louvain` ships usable types** (GraphLoop typechecks against it). If Codex hits a missing-types error, add a 1-line ambient `declare module` shim rather than `@ts-ignore`.
12. **One Orama index per notebook.** The adapter keys its index by notebook id and recreates it on notebook switch; Phase 1 retrieves over the active notebook's in-memory `JournalState` only (no cross-notebook aggregation).

---

## File Structure

**Created:**
- `vitest.config.ts` — Vitest config (node env, tsconfig paths).
- `supabase/migrations/20260617000000_journal_entries_provenance.sql` — add `entity_ids`/`relation_ids` columns.
- `src/lib/journal-rows.ts` — pure row↔`JournalEntry` mappers (extracted so they're testable without importing the Supabase client).
- `src/lib/journal-rows.test.ts` — provenance round-trip test.
- `src/lib/graphloop/types.ts` — vendored, trimmed to the retrieval type subset.
- `src/lib/graphloop/noise.ts` — vendored, trimmed to `normalizeName` + `DEFAULT_NOISE_NAMES`.
- `src/lib/graphloop/graph-ops.ts` — vendored verbatim.
- `src/lib/graphloop/search-index.ts` — vendored verbatim (+ one eslint-disable for vendored `any`).
- `src/lib/graphloop/communities.ts` — vendored verbatim.
- `src/lib/graphloop/embed.ts` — vendored verbatim (dormant).
- `src/lib/graphloop/retrieve.ts` — vendored verbatim.
- `src/lib/graphloop/index.ts` — barrel.
- `src/lib/graphloop/graph-ops.test.ts`, `search-index.test.ts`, `communities.test.ts`, `retrieve.test.ts` — ported tests (fixtures rebuilt as plain literals).
- `src/lib/journal-memory.ts` — adapter: `toGraphState`, per-notebook `SearchIndex`, `retrieveMemory`, `resetMemoryIndex`.
- `src/lib/journal-memory.test.ts` — adapter integration test.

**Modified:**
- `package.json` — add deps + `test`/`test:watch` scripts.
- `src/lib/journal-store.ts` — use the extracted mappers; write `entity_ids`/`relation_ids` in `saveState`.
- `src/routes/index.tsx` — register `get_relevant_memory`, handle it, reset index on notebook load/clear.
- `src/lib/conversation-policy.ts` — document the second private tool.

---

## Task 0: Stand up Vitest

**Files:**
- Modify: `package.json`
- Create: `vitest.config.ts`
- Create (temporary): `src/lib/__smoke__.test.ts`

- [ ] **Step 1: Install Vitest**

Run: `npm install -D vitest@^3`
Expected: `vitest` appears in `devDependencies`; install completes without peer-dep errors against Vite 7.

- [ ] **Step 2: Create `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    environment: "node",
    include: ["src/**/*.{test,spec}.{ts,tsx}"],
  },
});
```

- [ ] **Step 3: Add test scripts to `package.json`**

In the `"scripts"` block, add:
```json
    "test": "vitest run",
    "test:watch": "vitest",
```

- [ ] **Step 4: Write a smoke test to prove the harness runs**

Create `src/lib/__smoke__.test.ts`:
```ts
import { describe, expect, test } from "vitest";

describe("vitest harness", () => {
  test("runs", () => {
    expect(1 + 1).toBe(2);
  });
});
```

- [ ] **Step 5: Run it**

Run: `npx vitest run src/lib/__smoke__.test.ts`
Expected: PASS, 1 test.

- [ ] **Step 6: Delete the smoke test**

Run: `rm src/lib/__smoke__.test.ts`

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json vitest.config.ts
git commit -m "test: add vitest harness (node env, tsconfig paths)"
```

---

## Task 1: Durable provenance — pure row mappers

This is the spec prerequisite. We extract the journal-entry row mappers into a pure module so the round-trip is testable without importing the Supabase browser client.

**Files:**
- Create: `src/lib/journal-rows.ts`
- Create: `src/lib/journal-rows.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/lib/journal-rows.test.ts`:
```ts
import { describe, expect, test } from "vitest";
import { journalEntryToRow, rowToEntry } from "./journal-rows";
import type { JournalEntry } from "./journal-types";

describe("journal-rows provenance", () => {
  test("round-trips entityIds and relationIds through the row shape", () => {
    const entry: JournalEntry = {
      id: "je-1",
      text: "Maya leads Atlas",
      createdAt: "2026-06-17T00:00:00.000Z",
      entityIds: ["maya", "atlas"],
      relationIds: ["maya__leads__atlas"],
    };
    const row = journalEntryToRow(entry, "u1", "nb1");
    expect(row.entity_ids).toEqual(["maya", "atlas"]);
    expect(row.relation_ids).toEqual(["maya__leads__atlas"]);

    const back = rowToEntry(row);
    expect(back.entityIds).toEqual(["maya", "atlas"]);
    expect(back.relationIds).toEqual(["maya__leads__atlas"]);
  });

  test("rowToEntry defaults missing arrays to empty (old rows)", () => {
    const back = rowToEntry({ id: "je-2", text: "x", created_at: "t" });
    expect(back.entityIds).toEqual([]);
    expect(back.relationIds).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/journal-rows.test.ts`
Expected: FAIL — `Cannot find module './journal-rows'`.

- [ ] **Step 3: Create `src/lib/journal-rows.ts`**

```ts
import type { JournalEntry } from "./journal-types";

/**
 * Pure mappers between a `journal_entries` Supabase row and a JournalEntry.
 * Extracted from journal-store so the entityIds/relationIds provenance
 * round-trip is testable without importing the Supabase browser client.
 */
export function journalEntryToRow(entry: JournalEntry, userId: string, notebookId: string) {
  return {
    id: entry.id,
    user_id: userId,
    notebook_id: notebookId,
    text: entry.text,
    created_at: entry.createdAt,
    entity_ids: entry.entityIds,
    relation_ids: entry.relationIds,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function rowToEntry(r: any): JournalEntry {
  return {
    id: r.id,
    text: r.text,
    createdAt: r.created_at,
    entityIds: r.entity_ids ?? [],
    relationIds: r.relation_ids ?? [],
  };
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run src/lib/journal-rows.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/journal-rows.ts src/lib/journal-rows.test.ts
git commit -m "feat: pure journal-entry row mappers with provenance arrays"
```

---

## Task 2: Wire the provenance mappers into the store + migration

**Files:**
- Modify: `src/lib/journal-store.ts`
- Create: `supabase/migrations/20260617000000_journal_entries_provenance.sql`

- [ ] **Step 1: Create the migration**

Create `supabase/migrations/20260617000000_journal_entries_provenance.sql`:
```sql
-- Durable provenance for GraphRAG retrieval: persist which entities/relations
-- each journal entry produced, so grounded source passages survive a reload.
alter table journal_entries
  add column if not exists entity_ids   text[] not null default '{}',
  add column if not exists relation_ids text[] not null default '{}';
```

- [ ] **Step 2: Import the extracted mappers in `journal-store.ts`**

At the top of `src/lib/journal-store.ts`, after the existing imports, add:
```ts
import { journalEntryToRow, rowToEntry } from "./journal-rows";
```

- [ ] **Step 3: Replace the private `rowToEntry` in `journal-store.ts`**

Delete the local definition (the `function rowToEntry(r: any): JournalEntry { ... }` block near the bottom, currently around [src/lib/journal-store.ts:471](../../../src/lib/journal-store.ts)) **including its `// eslint-disable-next-line` comment line**. The imported `rowToEntry` now satisfies the existing call in `loadState`.

- [ ] **Step 4: Use `journalEntryToRow` in `saveState`**

In `saveState`, replace the `journal_entries` insert block (currently):
```ts
  if (state.entries.length) {
    await supabase.from("journal_entries").insert(
      state.entries.map((e) => ({
        id: e.id, user_id: userId, notebook_id: notebookId,
        text: e.text, created_at: e.createdAt,
      })),
    );
  }
```
with:
```ts
  if (state.entries.length) {
    await supabase.from("journal_entries").insert(
      state.entries.map((e) => journalEntryToRow(e, userId, notebookId)),
    );
  }
```

- [ ] **Step 5: Typecheck the change**

Run: `npx tsc --noEmit`
Expected: no new errors in `journal-store.ts` (the duplicate `rowToEntry` is gone; the import resolves).

> If `tsc --noEmit` surfaces unrelated pre-existing errors elsewhere, confirm they exist on `git stash` too; only `journal-store.ts`/`journal-rows.ts` should be affected by this task.

- [ ] **Step 6: Re-run the provenance test (regression)**

Run: `npx vitest run src/lib/journal-rows.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 7: Commit**

```bash
git add src/lib/journal-store.ts supabase/migrations/20260617000000_journal_entries_provenance.sql
git commit -m "feat: persist journal-entry provenance (entity_ids/relation_ids)"
```

---

## Task 3: Add retrieval dependencies + vendored foundation (types, noise)

**Files:**
- Modify: `package.json`
- Create: `src/lib/graphloop/types.ts`
- Create: `src/lib/graphloop/noise.ts`

- [ ] **Step 1: Install retrieval deps**

Run: `npm install @orama/orama@^3 graphology@^0.26 graphology-communities-louvain@^2`
Expected: all three appear in `dependencies`.

- [ ] **Step 2: Create `src/lib/graphloop/types.ts` (trimmed vendored)**

```ts
// Vendored from github.com/Hostileoracle0606/graphloop (src/types.ts), 2026-06-17.
// Trimmed to the retrieval subset. Lumen's own Entity/Relation/JournalEntry in
// src/lib/journal-types.ts are structurally identical to Entity/Relation/GraphEntry here.

export type EntityType =
  | "person" | "place" | "organization" | "project" | "event"
  | "activity" | "concept" | "emotion" | "other";

export interface Entity {
  id: string;
  name: string;
  type: EntityType;
  description?: string;
  metadata: Record<string, string | number | boolean>;
  mentions: number;
  firstSeen: string;
  lastSeen: string;
  questions?: string[];
}

export interface Relation {
  id: string;
  source: string;
  target: string;
  label: string;
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  supersededAt?: string;
}

export interface GraphEntry {
  id: string;
  text: string;
  createdAt: string;
  entityIds: string[];
  relationIds: string[];
}

export interface GraphState {
  entities: Record<string, Entity>;
  relations: Record<string, Relation>;
  entries: GraphEntry[];
}

export const emptyState = (): GraphState => ({ entities: {}, relations: {}, entries: [] });

export interface RankWeights {
  relevance: number;
  recency: number;
  importance: number;
  confidence: number;
}

export const DEFAULT_RANK_WEIGHTS: RankWeights = {
  relevance: 1.0,
  recency: 0.3,
  importance: 0.4,
  confidence: 0.3,
};

export interface RetrievalOptions {
  hops?: number;          // default 2
  maxEntities?: number;   // default 24
  maxRelations?: number;  // default 48
  tier?: "local" | "global" | "auto";   // default "auto"
  mode?: "lexical" | "hybrid" | "auto";  // default "auto" (hybrid iff embeddingModel)
  weights?: Partial<RankWeights>;
}

export interface CommunitySummary {
  id: number;
  label: string;
  entityIds: string[];
  size: number;
  topEntities: string[];
}

export interface RetrievalResult {
  entities: Entity[];
  relations: Relation[];
  entries: GraphEntry[];
  seeds: string[];
  communities?: CommunitySummary[];
  context: string;
}
```

- [ ] **Step 3: Create `src/lib/graphloop/noise.ts` (trimmed vendored)**

```ts
// Vendored from graphloop src/noise.ts (2026-06-17), trimmed to normalizeName.
// filterNoise was dropped (Lumen does its own noise filtering in extract-graph).

export const DEFAULT_NOISE_NAMES = new Set([
  "i", "me", "my", "mine", "you", "your", "yours", "we", "us", "our",
  "they", "them", "their",
  "today", "yesterday", "tomorrow", "morning", "afternoon", "evening",
  "night", "now", "later",
]);

export const normalizeName = (name: string): string =>
  name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9 ]+/g, "").trim();
```

- [ ] **Step 4: Typecheck**

Run: `npx tsc --noEmit`
Expected: no errors in the two new files.

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json src/lib/graphloop/types.ts src/lib/graphloop/noise.ts
git commit -m "feat: add retrieval deps + vendored graphloop types/noise foundation"
```

---

## Task 4: Vendor graph-ops + test

**Files:**
- Create: `src/lib/graphloop/graph-ops.ts`
- Create: `src/lib/graphloop/graph-ops.test.ts`

- [ ] **Step 1: Write the failing test (fixtures as plain literals)**

Create `src/lib/graphloop/graph-ops.test.ts`:
```ts
import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { activeRelations, buildNeighbors, relationUncertainty } from "./graph-ops";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string, name: string): Entity => ({
  id, name, type: "concept", metadata: {}, mentions: 1, firstSeen: T, lastSeen: T,
});
const rel = (source: string, target: string, label: string): Relation => ({
  id: `${source}__${label}__${target}`, source, target, label, metadata: {}, createdAt: T,
});

// Two people both linked to "atlas", surfaced in separate entries.
const seed = (): GraphState => {
  const r1 = rel("maya", "atlas", "on");
  const r2 = rel("sam", "atlas", "on");
  return {
    entities: { maya: ent("maya", "Maya"), sam: ent("sam", "Sam"), atlas: ent("atlas", "Atlas") },
    relations: { [r1.id]: r1, [r2.id]: r2 },
    entries: [
      { id: "e1", text: "Maya on Atlas", createdAt: T, entityIds: ["maya", "atlas"], relationIds: [r1.id] },
      { id: "e2", text: "Sam on Atlas", createdAt: T, entityIds: ["sam", "atlas"], relationIds: [r2.id] },
    ],
  };
};

describe("graph-ops", () => {
  test("activeRelations excludes superseded relations", () => {
    const s = seed();
    const rid = Object.keys(s.relations)[0]!;
    s.relations[rid] = { ...s.relations[rid]!, supersededAt: T };
    expect(activeRelations(s).map((r) => r.id)).not.toContain(rid);
  });

  test("buildNeighbors is symmetric", () => {
    const n = buildNeighbors(activeRelations(seed()));
    expect(n.get("maya")?.has("atlas")).toBe(true);
    expect(n.get("atlas")?.has("maya")).toBe(true);
  });

  test("relationUncertainty scores a single fresh cross-entry relation >= 2", () => {
    const scores = relationUncertainty(seed());
    const first = [...scores.values()][0]!;
    expect(first).toBeGreaterThanOrEqual(2);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/graphloop/graph-ops.test.ts`
Expected: FAIL — `Cannot find module './graph-ops'`.

- [ ] **Step 3: Create `src/lib/graphloop/graph-ops.ts` (vendored verbatim)**

```ts
import type { GraphState, Relation } from "./types";

/** Count whitespace-separated words in a string (empty/undefined → 0). */
export const wordCount = (s: string | undefined): number =>
  s ? s.trim().split(/\s+/).filter(Boolean).length : 0;

/** Relations that have not been soft-deleted via supersededAt. */
export const activeRelations = (state: GraphState): Relation[] =>
  Object.values(state.relations).filter((r) => !r.supersededAt);

/** Undirected adjacency built from a relation list. */
export function buildNeighbors(relations: Relation[]): Map<string, Set<string>> {
  const neighbors = new Map<string, Set<string>>();
  for (const r of relations) {
    if (!neighbors.has(r.source)) neighbors.set(r.source, new Set());
    if (!neighbors.has(r.target)) neighbors.set(r.target, new Set());
    neighbors.get(r.source)!.add(r.target);
    neighbors.get(r.target)!.add(r.source);
  }
  return neighbors;
}

/**
 * Uncertainty score (0-3) per active relation. Mirrors the prior inline agenda
 * logic: +1 if mentioned <= once, +1 if endpoints first appeared in different
 * entries, +1 if it is the only active relation for that ordered pair.
 */
export function relationUncertainty(state: GraphState): Map<string, number> {
  const active = activeRelations(state);
  const mentionCountByRelation = new Map<string, number>();
  const firstEntryByEntity = new Map<string, string>();
  // entries are newest-first; iterate reversed so last write = oldest entry
  for (const entry of state.entries.slice().reverse()) {
    for (const rid of entry.relationIds) {
      mentionCountByRelation.set(rid, (mentionCountByRelation.get(rid) ?? 0) + 1);
    }
    for (const eid of entry.entityIds) {
      firstEntryByEntity.set(eid, entry.id);
    }
  }
  const activePairCount = new Map<string, number>();
  for (const r of active) {
    const key = `${r.source} ${r.target}`;
    activePairCount.set(key, (activePairCount.get(key) ?? 0) + 1);
  }
  const scores = new Map<string, number>();
  for (const r of active) {
    let score = 0;
    if ((mentionCountByRelation.get(r.id) ?? 0) <= 1) score += 1;
    const se = firstEntryByEntity.get(r.source);
    const te = firstEntryByEntity.get(r.target);
    if (se && te && se !== te) score += 1;
    if ((activePairCount.get(`${r.source} ${r.target}`) ?? 0) <= 1) score += 1;
    scores.set(r.id, score);
  }
  return scores;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run src/lib/graphloop/graph-ops.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/graphloop/graph-ops.ts src/lib/graphloop/graph-ops.test.ts
git commit -m "feat: vendor graphloop graph-ops (active/neighbors/uncertainty)"
```

---

## Task 5: Vendor search-index (Orama) + test

**Files:**
- Create: `src/lib/graphloop/search-index.ts`
- Create: `src/lib/graphloop/search-index.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/lib/graphloop/search-index.test.ts`:
```ts
import { describe, expect, test } from "vitest";
import type { Entity } from "./types";
import { SearchIndex } from "./search-index";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string, name: string, description?: string): Entity => ({
  id, name, type: "concept", description, metadata: {}, mentions: 1, firstSeen: T, lastSeen: T,
});

describe("SearchIndex (lexical)", () => {
  test("BM25 finds an entity by name token", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("project-atlas", "Project Atlas"), ent("maya", "Maya")]);
    const hits = await idx.search("atlas", undefined, 5);
    expect(hits[0]?.id).toBe("project-atlas");
  });

  test("incremental sync only re-indexes changed entities", async () => {
    const idx = new SearchIndex();
    const first = await idx.sync([ent("maya", "Maya")]);
    const again = await idx.sync([ent("maya", "Maya")]);
    expect(first.indexed).toBe(1);
    expect(again.indexed).toBe(0); // unchanged → skipped
  });

  test("returns empty for a no-match query", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("maya", "Maya")]);
    expect(await idx.search("nonexistentxyz", undefined, 5)).toEqual([]);
  });

  test("deletion: removed entity no longer appears in search", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("project-atlas", "Project Atlas"), ent("maya", "Maya")]);
    await idx.sync([ent("maya", "Maya")]); // Atlas dropped from the set
    const hits = await idx.search("atlas", undefined, 5);
    expect(hits.map((h) => h.id)).not.toContain("project-atlas");
  });

  test("content change re-indexes: new description is findable", async () => {
    const idx = new SearchIndex();
    const first = await idx.sync([ent("maya", "Maya", "original bio")]);
    expect(first.indexed).toBe(1);
    const second = await idx.sync([ent("maya", "Maya", "galactic engineer")]);
    expect(second.indexed).toBe(1);
    const hits = await idx.search("galactic", undefined, 5);
    expect(hits.map((h) => h.id)).toContain("maya");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/graphloop/search-index.test.ts`
Expected: FAIL — `Cannot find module './search-index'`.

- [ ] **Step 3: Create `src/lib/graphloop/search-index.ts` (vendored verbatim)**

```ts
/* eslint-disable @typescript-eslint/no-explicit-any */
import { create, removeMultiple, search, upsertMultiple } from "@orama/orama";
import type { Entity } from "./types";

export interface SearchHit {
  id: string;
  score: number;
}

const contentHash = (e: Entity): string =>
  `${e.lastSeen}|${e.name}|${e.description ?? ""}`;

const docFor = (e: Entity, vec?: number[]) => ({
  id: e.id,
  name: e.name,
  description: e.description ?? "",
  ...(vec ? { embedding: vec } : {}),
});

/**
 * Orama-backed index over entities. BM25 by default; hybrid when vectors are
 * supplied. The Orama db is created lazily on first sync so the vector field
 * dimension can be derived from the first embedding.
 */
export class SearchIndex {
  private db: Awaited<ReturnType<typeof create>> | null = null;
  private hashes = new Map<string, string>();
  private vectorDim: number | null = null;

  private async ensureDb(dim: number | null) {
    if (this.db && this.vectorDim === dim) return;
    this.vectorDim = dim;
    this.db = await create({
      schema: {
        name: "string",
        description: "string",
        ...(dim ? { embedding: `vector[${dim}]` as const } : {}),
      },
    });
    this.hashes.clear(); // schema changed → reindex everything next sync
  }

  /** Sync entities into the index. Returns how many docs were (re)indexed. */
  async sync(entities: Entity[], vectors?: Map<string, number[]>): Promise<{ indexed: number }> {
    const dim = vectors && vectors.size > 0
      ? (vectors.values().next().value?.length ?? null)
      : (this.vectorDim ?? null);
    await this.ensureDb(dim);

    const present = new Set(entities.map((e) => e.id));

    const pendingHashes = new Map<string, string>();
    const changed: Entity[] = [];
    for (const e of entities) {
      const h = `${contentHash(e)}|${vectors?.get(e.id) ? "v" : "n"}`;
      if (this.hashes.get(e.id) !== h) {
        changed.push(e);
        pendingHashes.set(e.id, h);
      }
    }
    const removed = [...this.hashes.keys()].filter((id) => !present.has(id));

    if (removed.length) {
      await removeMultiple(this.db!, removed);
      for (const id of removed) this.hashes.delete(id);
    }
    if (changed.length) {
      await upsertMultiple(this.db!, changed.map((e) => docFor(e, vectors?.get(e.id))));
      for (const [id, h] of pendingHashes) this.hashes.set(id, h);
    }
    return { indexed: changed.length };
  }

  /** BM25 (and vector, if queryVector given) search. Returns ranked hits. */
  async search(term: string, queryVector: number[] | undefined, limit: number): Promise<SearchHit[]> {
    if (!this.db) return [];
    const params: Record<string, unknown> =
      queryVector && this.vectorDim
        ? {
            term,
            mode: "hybrid",
            vector: { value: queryVector, property: "embedding" },
            similarity: 0.0,
            limit,
          }
        : { term, properties: ["name", "description"], limit };
    const res: any = await search(this.db, params as any);
    return (res?.hits ?? []).map((h: any) => ({ id: h.id as string, score: h.score as number }));
  }
}
```

> Note: the verbatim upstream file also imports `insertMultiple`; it is unused, so it is omitted here to keep `npm run lint` green. This is the only edit to the vendored search-index.

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run src/lib/graphloop/search-index.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/graphloop/search-index.ts src/lib/graphloop/search-index.test.ts
git commit -m "feat: vendor graphloop SearchIndex (Orama BM25)"
```

---

## Task 6: Vendor communities (Louvain) + test

**Files:**
- Create: `src/lib/graphloop/communities.ts`
- Create: `src/lib/graphloop/communities.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/lib/graphloop/communities.test.ts`:
```ts
import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { buildCommunities } from "./communities";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string): Entity => ({
  id, name: id.toUpperCase(), type: "concept", metadata: {}, mentions: 1, firstSeen: T, lastSeen: T,
});
const rel = (source: string, target: string): Relation => ({
  id: `${source}__rel__${target}`, source, target, label: "rel", metadata: {}, createdAt: T,
});
const state = (rels: Relation[]): GraphState => {
  const entities: Record<string, Entity> = {};
  const relations: Record<string, Relation> = {};
  for (const r of rels) {
    entities[r.source] ??= ent(r.source);
    entities[r.target] ??= ent(r.target);
    relations[r.id] = r;
  }
  return { entities, relations, entries: [] };
};

describe("buildCommunities", () => {
  test("returns empty for a graph with no active relations", () => {
    expect(buildCommunities({ entities: { a: ent("a") }, relations: {}, entries: [] })).toEqual([]);
  });

  test("separates two disconnected clusters into communities", () => {
    const comms = buildCommunities(
      state([rel("a1", "a2"), rel("a2", "a3"), rel("b1", "b2"), rel("b2", "b3")]),
    );
    expect(comms.length).toBeGreaterThanOrEqual(2);
    expect(comms[0]!.topEntities.length).toBeGreaterThan(0);
    expect(comms[0]!.label.length).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/graphloop/communities.test.ts`
Expected: FAIL — `Cannot find module './communities'`.

- [ ] **Step 3: Create `src/lib/graphloop/communities.ts` (vendored verbatim)**

```ts
import Graph from "graphology";
import louvain from "graphology-communities-louvain";
import type { CommunitySummary, GraphState } from "./types";
import { activeRelations } from "./graph-ops";

export function buildCommunities(state: GraphState): CommunitySummary[] {
  const active = activeRelations(state);
  if (active.length === 0) return [];

  const g = new Graph({ type: "undirected", multi: false, allowSelfLoops: false });
  for (const r of active) {
    if (!g.hasNode(r.source)) g.addNode(r.source);
    if (!g.hasNode(r.target)) g.addNode(r.target);
    if (r.source !== r.target && !g.hasEdge(r.source, r.target)) g.addEdge(r.source, r.target);
  }

  const partition = louvain(g) as Record<string, number>;
  const groups = new Map<number, string[]>();
  for (const [nodeId, cid] of Object.entries(partition)) {
    if (!groups.has(cid)) groups.set(cid, []);
    groups.get(cid)!.push(nodeId);
  }

  const summaries: CommunitySummary[] = [];
  for (const [cid, ids] of groups) {
    const ranked = ids
      .map((id) => ({ id, mentions: state.entities[id]?.mentions ?? 0, degree: g.degree(id) }))
      .sort((a, b) => (b.degree - a.degree) || (b.mentions - a.mentions));
    const topEntities = ranked.slice(0, 5).map((r) => state.entities[r.id]?.name ?? r.id);
    summaries.push({
      id: cid,
      label: topEntities.slice(0, 3).join(", "),
      entityIds: ranked.map((r) => r.id),
      size: ids.length,
      topEntities,
    });
  }
  return summaries.sort((a, b) => b.size - a.size);
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run src/lib/graphloop/communities.test.ts`
Expected: PASS, 2 tests.

> If TypeScript reports no types for `graphology-communities-louvain`, create `src/lib/graphloop/graphology-louvain.d.ts` with:
> ```ts
> declare module "graphology-communities-louvain" {
>   import type Graph from "graphology";
>   const louvain: (graph: Graph) => Record<string, number>;
>   export default louvain;
> }
> ```

- [ ] **Step 5: Commit**

```bash
git add src/lib/graphloop/communities.ts src/lib/graphloop/communities.test.ts
git commit -m "feat: vendor graphloop communities (Louvain global tier)"
```

---

## Task 7: Vendor embed + retrieve + barrel, then test retrieve

**Files:**
- Create: `src/lib/graphloop/embed.ts`
- Create: `src/lib/graphloop/retrieve.ts`
- Create: `src/lib/graphloop/index.ts`
- Create: `src/lib/graphloop/retrieve.test.ts`

- [ ] **Step 1: Write the failing test (fixture with provenance entries)**

Create `src/lib/graphloop/retrieve.test.ts`:
```ts
import { describe, expect, test } from "vitest";
import type { Entity, GraphState, Relation } from "./types";
import { SearchIndex } from "./search-index";
import { retrieve } from "./retrieve";
import { buildCommunities } from "./communities";

const FIXED_NOW = Date.parse("2026-06-12T00:00:00.000Z");
const T = "2026-06-12T00:00:00.000Z";

const ent = (id: string, name: string, type: Entity["type"]): Entity => ({
  id, name, type, metadata: {}, mentions: 1, firstSeen: T, lastSeen: T,
});
const rel = (source: string, target: string, label: string): Relation => ({
  id: `${source}__${label}__${target}`, source, target, label, metadata: {}, createdAt: T,
});

const fixture = (): GraphState => {
  const r1 = rel("maya", "project-atlas", "leads");
  const r2 = rel("sam", "project-atlas", "works_on");
  const r3 = rel("lin", "coffee", "likes");
  return {
    entities: {
      maya: ent("maya", "Maya", "person"),
      "project-atlas": ent("project-atlas", "Project Atlas", "project"),
      sam: ent("sam", "Sam", "person"),
      lin: ent("lin", "Lin", "person"),
      coffee: ent("coffee", "coffee", "concept"),
    },
    relations: { [r1.id]: r1, [r2.id]: r2, [r3.id]: r3 },
    entries: [
      { id: "e1", text: "Maya leads Project Atlas", createdAt: T, entityIds: ["maya", "project-atlas"], relationIds: [r1.id] },
      { id: "e2", text: "Sam works on Project Atlas", createdAt: T, entityIds: ["sam", "project-atlas"], relationIds: [r2.id] },
      { id: "e3", text: "Lin likes coffee", createdAt: T, entityIds: ["lin", "coffee"], relationIds: [r3.id] },
    ],
  };
};

const makeIndex = async (s: GraphState) => {
  const idx = new SearchIndex();
  await idx.sync(Object.values(s.entities));
  return idx;
};

describe("retrieve (local, lexical)", () => {
  test("returns the seed and its neighborhood, excludes unrelated", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    const names = r.entities.map((e) => e.name);
    expect(names).toContain("Project Atlas");
    expect(names).toContain("Maya"); // 1-hop neighbor
    expect(names).not.toContain("coffee"); // unrelated subgraph
  });

  test("attaches provenance entries for retrieved nodes", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.entries.some((e) => e.text.includes("Maya leads Project Atlas"))).toBe(true);
  });

  test("packs a context string with entities, relations, and sources", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.context).toContain("Project Atlas");
    expect(r.context).toMatch(/--leads-->|--works_on-->/);
    expect(r.context).toContain("## Sources");
  });

  test("empty query returns empty result", async () => {
    const s = fixture();
    const r = await retrieve(s, "   ", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.entities).toEqual([]);
    expect(r.context).toBe("");
  });

  test("never returns a dangling relation (both endpoints kept)", async () => {
    const s = fixture();
    const r = await retrieve(s, "atlas", { maxEntities: 2 }, { index: await makeIndex(s), now: FIXED_NOW });
    const keptIds = new Set(r.entities.map((e) => e.id));
    for (const rl of r.relations) {
      expect(keptIds.has(rl.source) && keptIds.has(rl.target)).toBe(true);
    }
  });

  test("excludes superseded relations from expansion", async () => {
    const s = fixture();
    const rid = "maya__leads__project-atlas";
    s.relations[rid] = { ...s.relations[rid]!, supersededAt: T };
    const r = await retrieve(s, "maya", {}, { index: await makeIndex(s), now: FIXED_NOW });
    expect(r.relations.map((rl) => rl.id)).not.toContain(rid);
  });

  test("falls back to community summaries when no seed matches", async () => {
    const s = fixture();
    const r = await retrieve(
      s, "totallyunrelatedquery", {},
      { index: await makeIndex(s), now: FIXED_NOW, communities: buildCommunities(s) },
    );
    expect(r.entities).toEqual([]);
    expect(r.communities?.length ?? 0).toBeGreaterThan(0);
    expect(r.context).toContain("Relevant areas of memory");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/graphloop/retrieve.test.ts`
Expected: FAIL — `Cannot find module './retrieve'`.

- [ ] **Step 3: Create `src/lib/graphloop/embed.ts` (vendored verbatim, dormant)**

```ts
import { embedMany, type EmbeddingModel } from "ai";

/** Embed an array of texts via the AI SDK. Returns one vector per input. */
export async function embedTexts(model: EmbeddingModel, texts: string[]): Promise<number[][]> {
  if (texts.length === 0) return [];
  const { embeddings } = await embedMany({ model, values: texts });
  return embeddings;
}
```

- [ ] **Step 4: Create `src/lib/graphloop/retrieve.ts` (vendored verbatim)**

```ts
import type {
  CommunitySummary, Entity, GraphState, RankWeights, Relation,
  RetrievalOptions, RetrievalResult,
} from "./types";
import { DEFAULT_RANK_WEIGHTS } from "./types";
import { activeRelations, buildNeighbors, relationUncertainty, wordCount } from "./graph-ops";
import { normalizeName } from "./noise";
import { embedTexts } from "./embed";
import type { SearchIndex } from "./search-index";
import type { EmbeddingModel } from "ai";

export interface RetrieveDeps {
  index: SearchIndex;
  embedModel?: EmbeddingModel;
  communities?: CommunitySummary[];
  now?: number;
}

const MAX_COMMUNITY_SUMMARIES = 5;

const emptyResult = (): RetrievalResult => ({
  entities: [], relations: [], entries: [], seeds: [], context: "",
});

function resolveOptions(opts: RetrievalOptions | undefined, deps: RetrieveDeps) {
  const o = opts ?? {};
  const rawMode = o.mode ?? "auto";
  const mode: "lexical" | "hybrid" =
    rawMode === "auto" ? (deps.embedModel ? "hybrid" : "lexical") : rawMode;
  return {
    hops: o.hops ?? 2,
    maxEntities: o.maxEntities ?? 24,
    maxRelations: o.maxRelations ?? 48,
    tier: o.tier ?? "auto",
    mode,
    weights: { ...DEFAULT_RANK_WEIGHTS, ...(o.weights ?? {}) } as RankWeights,
  };
}

export async function retrieve(
  state: GraphState,
  query: string,
  opts: RetrievalOptions | undefined,
  deps: RetrieveDeps,
): Promise<RetrievalResult> {
  const q = query.trim();
  if (!q) return emptyResult();
  const o = resolveOptions(opts, deps);
  const now = deps.now ?? Date.now();

  // ---- 1. seed selection ----
  let queryVector: number[] | undefined;
  if (o.mode === "hybrid" && deps.embedModel) {
    try { queryVector = (await embedTexts(deps.embedModel, [q]))[0]; }
    catch { queryVector = undefined; } // graceful fallback to BM25
  }
  const hits = await deps.index.search(q, queryVector, o.maxEntities * 2);
  const seedScore = new Map<string, number>();
  for (const h of hits) seedScore.set(h.id, Math.max(seedScore.get(h.id) ?? 0, h.score));

  // always include exact normalized-name matches
  const nq = normalizeName(q);
  for (const e of Object.values(state.entities)) {
    const nn = normalizeName(e.name);
    if (nn.length >= 2 && nq.includes(nn)) seedScore.set(e.id, Math.max(seedScore.get(e.id) ?? 0, 1));
  }
  const seeds = [...seedScore.keys()].filter((id) => state.entities[id]);

  // normalize seed scores to [0,1]
  const maxSeed = Math.max(1, ...seeds.map((id) => seedScore.get(id) ?? 0));
  const seedRel = new Map(seeds.map((id) => [id, (seedScore.get(id) ?? 0) / maxSeed]));

  if (seeds.length === 0 || o.tier === "global") {
    return globalResult(deps.communities ?? []);
  }

  // ---- 2. expansion (BFS k-hop over active relations) ----
  const active = activeRelations(state);
  const neighbors = buildNeighbors(active);
  const hop = new Map<string, number>();
  for (const s of seeds) hop.set(s, 0);
  let frontier = [...seeds];
  for (let d = 1; d <= o.hops; d++) {
    const next: string[] = [];
    for (const id of frontier) {
      for (const nb of neighbors.get(id) ?? []) {
        if (!hop.has(nb)) { hop.set(nb, d); next.push(nb); }
      }
    }
    frontier = next;
  }

  // ---- 3 + 4. provenance prep + ranking ----
  const uncertainty = relationUncertainty(state);
  const relByEntity = new Map<string, Relation[]>();
  for (const r of active) {
    if (!relByEntity.has(r.source)) relByEntity.set(r.source, []);
    if (!relByEntity.has(r.target)) relByEntity.set(r.target, []);
    relByEntity.get(r.source)!.push(r);
    relByEntity.get(r.target)!.push(r);
  }
  const maxMentions = Math.max(1, ...Object.values(state.entities).map((e) => e.mentions));

  const scored = [...hop.keys()]
    .map((id) => {
      const e = state.entities[id];
      if (!e) return null;
      const d = hop.get(id) ?? 0;
      const relevance = (d === 0 ? (seedRel.get(id) ?? 1) : 0.5) * Math.pow(0.6, d);
      const ageDays = Math.max(0, (now - Date.parse(e.lastSeen)) / 86_400_000);
      const recency = Math.exp(-ageDays / 30);
      const importance = Math.log(e.mentions + 1) / Math.log(maxMentions + 1);
      const incident = relByEntity.get(id) ?? [];
      const confidence = incident.length
        ? incident.reduce((acc, r) => acc + (1 - (uncertainty.get(r.id) ?? 0) / 3), 0) / incident.length
        : Math.min(1, wordCount(e.description) / 30);
      const total =
        o.weights.relevance * relevance +
        o.weights.recency * recency +
        o.weights.importance * importance +
        o.weights.confidence * confidence;
      return { id, e, total };
    })
    .filter((x): x is { id: string; e: Entity; total: number } => x !== null)
    .sort((a, b) => b.total - a.total);

  // ---- 5. budget (keep connectivity) ----
  const keptEntities = scored.slice(0, o.maxEntities).map((s) => s.e);
  const keptIds = new Set(keptEntities.map((e) => e.id));
  const keptRelations = active
    .filter((r) => keptIds.has(r.source) && keptIds.has(r.target))
    .slice(0, o.maxRelations);

  // ---- provenance entries ----
  const relIds = new Set(keptRelations.map((r) => r.id));
  const entries = state.entries.filter(
    (en) => en.entityIds.some((id) => keptIds.has(id)) || en.relationIds.some((id) => relIds.has(id)),
  );

  // ---- 6. pack ----
  const context = packContext(keptEntities, keptRelations, entries);
  return { entities: keptEntities, relations: keptRelations, entries, seeds, context };
}

function globalResult(communities: CommunitySummary[]): RetrievalResult {
  if (communities.length === 0) return emptyResult();
  const top = communities.slice(0, MAX_COMMUNITY_SUMMARIES);
  const lines = ["## Relevant areas of memory"];
  for (const c of top) lines.push(`- ${c.label} (${c.size} entities): ${c.topEntities.join(", ")}`);
  return { entities: [], relations: [], entries: [], seeds: [], communities: top, context: lines.join("\n") };
}

function packContext(entities: Entity[], relations: Relation[], entries: GraphState["entries"]): string {
  if (entities.length === 0) return "";
  const byId = new Map(entities.map((e) => [e.id, e]));
  const out: string[] = ["## Entities"];
  for (const e of entities) {
    const desc = e.description ? `: ${e.description}` : "";
    out.push(`- ${e.name} (${e.type})${desc} [mentions: ${e.mentions}]`);
  }
  if (relations.length) {
    out.push("## Relations");
    for (const r of relations) {
      const s = byId.get(r.source)?.name ?? r.source;
      const t = byId.get(r.target)?.name ?? r.target;
      out.push(`- ${s} --${r.label}--> ${t}`);
    }
  }
  if (entries.length) {
    out.push("## Sources");
    for (const en of entries.slice(0, 12)) out.push(`- "${en.text}"`);
  }
  return out.join("\n");
}
```

- [ ] **Step 5: Create `src/lib/graphloop/index.ts` (barrel)**

```ts
export { retrieve } from "./retrieve";
export type { RetrieveDeps } from "./retrieve";
export { SearchIndex } from "./search-index";
export type { SearchHit } from "./search-index";
export { buildCommunities } from "./communities";
export { activeRelations, buildNeighbors, relationUncertainty, wordCount } from "./graph-ops";
export { normalizeName, DEFAULT_NOISE_NAMES } from "./noise";
export { embedTexts } from "./embed";
export { emptyState, DEFAULT_RANK_WEIGHTS } from "./types";
export type {
  Entity, Relation, GraphEntry, GraphState, EntityType,
  RankWeights, RetrievalOptions, RetrievalResult, CommunitySummary,
} from "./types";
```

- [ ] **Step 6: Run it to verify it passes**

Run: `npx vitest run src/lib/graphloop/retrieve.test.ts`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add src/lib/graphloop/embed.ts src/lib/graphloop/retrieve.ts src/lib/graphloop/index.ts src/lib/graphloop/retrieve.test.ts
git commit -m "feat: vendor graphloop retrieve + embed + barrel (lexical GraphRAG)"
```

---

## Task 8: Lumen adapter — `journal-memory.ts`

**Files:**
- Create: `src/lib/journal-memory.ts`
- Create: `src/lib/journal-memory.test.ts`

- [ ] **Step 1: Write the failing test**

Create `src/lib/journal-memory.test.ts`:
```ts
import { beforeEach, describe, expect, test } from "vitest";
import type { JournalState } from "./journal-types";
import { resetMemoryIndex, retrieveMemory, toGraphState } from "./journal-memory";

const T = "2026-06-17T00:00:00.000Z";

const fixture = (): JournalState => ({
  followUps: [],
  askedQuestions: [],
  entities: {
    maya: { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 1, firstSeen: T, lastSeen: T },
    "project-atlas": { id: "project-atlas", name: "Project Atlas", type: "project", metadata: {}, mentions: 1, firstSeen: T, lastSeen: T },
    coffee: { id: "coffee", name: "coffee", type: "concept", metadata: {}, mentions: 1, firstSeen: T, lastSeen: T },
  },
  relations: {
    "maya__leads__project-atlas": {
      id: "maya__leads__project-atlas", source: "maya", target: "project-atlas",
      label: "leads", metadata: {}, createdAt: T,
    },
  },
  entries: [
    { id: "e1", text: "Maya leads Project Atlas", createdAt: T, entityIds: ["maya", "project-atlas"], relationIds: ["maya__leads__project-atlas"] },
    { id: "e2", text: "I like coffee", createdAt: T, entityIds: ["coffee"], relationIds: [] },
  ],
});

beforeEach(() => resetMemoryIndex());

describe("journal-memory", () => {
  test("toGraphState picks the three graph fields", () => {
    const g = toGraphState(fixture());
    expect(Object.keys(g)).toEqual(["entities", "relations", "entries"]);
    expect(g.entities.maya?.name).toBe("Maya");
  });

  test("retrieveMemory returns grounded context for a known entity", async () => {
    const r = await retrieveMemory(fixture(), "atlas", "nb-1");
    expect(r.entities.map((e) => e.name)).toContain("Project Atlas");
    expect(r.context).toContain("## Sources");
    expect(r.context).toContain("Maya leads Project Atlas");
  });

  test("empty query returns an empty result", async () => {
    const r = await retrieveMemory(fixture(), "   ", "nb-1");
    expect(r.entities).toEqual([]);
    expect(r.context).toBe("");
  });

  test("no-match query returns a community fallback or honest empty (never the whole graph)", async () => {
    const r = await retrieveMemory(fixture(), "zzzznotpresent", "nb-1");
    expect(r.entities).toEqual([]); // never dumps unrelated nodes
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx vitest run src/lib/journal-memory.test.ts`
Expected: FAIL — `Cannot find module './journal-memory'`.

- [ ] **Step 3: Create `src/lib/journal-memory.ts`**

```ts
import type { JournalState } from "@/lib/journal-types";
import { SearchIndex } from "@/lib/graphloop/search-index";
import { buildCommunities } from "@/lib/graphloop/communities";
import { retrieve } from "@/lib/graphloop/retrieve";
import type { GraphState, RetrievalOptions, RetrievalResult } from "@/lib/graphloop/types";

const EMPTY_RESULT: RetrievalResult = {
  entities: [], relations: [], entries: [], seeds: [], context: "",
};

/**
 * Lumen JournalState → GraphLoop GraphState. The two share identical
 * Entity/Relation/Entry shapes, so this is a field pick, not a transform.
 * followUps/askedQuestions are intentionally dropped — retrieval never uses them.
 */
export function toGraphState(state: JournalState): GraphState {
  return { entities: state.entities, relations: state.relations, entries: state.entries };
}

// One Orama index per notebook. Recreated when the active notebook changes so a
// new session never searches a stale graph. Phase 1 scope = active notebook only.
let activeKey: string | null = null;
let index: SearchIndex | null = null;

function indexFor(key: string): SearchIndex {
  if (activeKey !== key || !index) {
    activeKey = key;
    index = new SearchIndex();
  }
  return index;
}

/** Drop the cached index (call on notebook switch / clear / fresh load). */
export function resetMemoryIndex(): void {
  activeKey = null;
  index = null;
}

/**
 * Retrieve memory relevant to `query` from the active notebook's JournalState.
 * Lexical BM25 + k-hop expansion + Louvain community fallback. No LLM calls.
 * Fail-closed: any error returns an empty result so a recall failure never
 * breaks the live turn.
 */
export async function retrieveMemory(
  state: JournalState,
  query: string,
  notebookKey: string,
  opts?: RetrievalOptions,
): Promise<RetrievalResult> {
  try {
    const q = query.trim();
    if (!q) return EMPTY_RESULT;
    const g = toGraphState(state);
    const idx = indexFor(notebookKey);
    await idx.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    return await retrieve(g, q, { mode: "lexical", ...opts }, { index: idx, communities });
  } catch (err) {
    console.warn("[journal-memory] retrieve failed", err);
    return EMPTY_RESULT;
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `npx vitest run src/lib/journal-memory.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/journal-memory.ts src/lib/journal-memory.test.ts
git commit -m "feat: journal-memory adapter (active-notebook lexical retrieval)"
```

---

## Task 9: Wire `get_relevant_memory` into the voice agent

No unit test (route + live session); verified via typecheck/build + a manual run step.

**Files:**
- Modify: `src/routes/index.tsx`
- Modify: `src/lib/conversation-policy.ts`

- [ ] **Step 1: Import the adapter in `index.tsx`**

Near the existing `import { extractGraph } from "@/lib/extract-graph";` line, add:
```ts
import { resetMemoryIndex, retrieveMemory } from "@/lib/journal-memory";
```

- [ ] **Step 2: Register the second tool in the `liveTools` memo**

In the `liveTools` `useMemo` array ([src/routes/index.tsx:766-776](../../../src/routes/index.tsx)), add a second declaration after the `get_graph_summary` object:
```ts
      {
        name: "get_relevant_memory",
        description:
          "Retrieve past memory relevant to a query from the user's knowledge graph: a focused packet of related entities, relations, and the exact things the user said (sources). Use this when the user references something from earlier or the past, or when grounding your reply in prior context would help. Distinct from get_graph_summary, which tells you what to ask next. The result is for YOUR planning only — never read it aloud.",
        parameters: {
          type: "OBJECT",
          properties: {
            query: { type: "STRING", description: "What to recall, in a few words (a name, topic, or phrase)." },
          },
          required: ["query"],
        },
      },
```

- [ ] **Step 3: Handle the tool call (async) in `handleToolCall`**

Replace the `handleToolCall` callback ([src/routes/index.tsx:781-787](../../../src/routes/index.tsx)) with:
```ts
  const handleToolCall = useCallback(
    async (call: GeminiToolCall) => {
      if (call.name === "get_graph_summary") return buildGraphSummary();
      if (call.name === "get_relevant_memory") {
        const query =
          typeof call.args?.query === "string" ? call.args.query : "";
        const { context } = await retrieveMemory(
          stateRef.current,
          query,
          notebookIdRef.current ?? "active",
        );
        return { context };
      }
      return { error: `Unknown tool: ${call.name}` };
    },
    [buildGraphSummary],
  );
```

> `stateRef` and `notebookIdRef` already exist in this component (used by `buildGraphSummary` and the load effect). If `call.args` is not typed to allow indexing, read it as `(call.args as Record<string, unknown> | undefined)?.query`.

- [ ] **Step 4: Reset the memory index when a notebook loads and on clear**

In the load effect, right after `setNotebookId(notebook.id)` / `notebookIdRef.current = notebook.id` ([src/routes/index.tsx:826-827](../../../src/routes/index.tsx)), add:
```ts
        resetMemoryIndex();
```
And in the clear-journal handler that sets `setState(EMPTY_STATE)` ([src/routes/index.tsx:997](../../../src/routes/index.tsx)), add right after it:
```ts
    resetMemoryIndex();
```

- [ ] **Step 5: Document the second tool in `conversation-policy.ts`**

In `GEMINI_LIVE_SYSTEM_INSTRUCTION`, immediately after the line `- sessionElapsedMin: how long the session has been running.` ([src/lib/conversation-policy.ts:308](../../../src/lib/conversation-policy.ts)), insert:
```ts

YOUR SECOND PRIVATE TOOL — get_relevant_memory({ query }):
Where get_graph_summary tells you what to ASK next, get_relevant_memory tells you what the user has already SAID that's relevant right now. It returns a focused packet: related entities, how they connect, and the user's own words (sources). Call it when the user refers back to something from earlier or the past ("that thing with my sister", "the project I mentioned"), or when grounding your reply in what they actually said would make you sound like you remember. Pass a few words as the query (a name, a topic, a phrase). The result is for YOUR planning only — never read it aloud, never quote the sources verbatim, never mention memory, the graph, or any field. Let it make your reply feel continuous, not retrieved.
```

- [ ] **Step 6: Typecheck and build**

Run: `npx tsc --noEmit`
Expected: no new errors.

Run: `npm run build`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/routes/index.tsx src/lib/conversation-policy.ts
git commit -m "feat: add get_relevant_memory tool to the voice agent"
```

---

## Task 10: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test suite**

Run: `npx vitest run`
Expected: all suites pass — `journal-rows` (2), `graph-ops` (3), `search-index` (5), `communities` (2), `retrieve` (7), `journal-memory` (4).

- [ ] **Step 2: Lint**

Run: `npm run lint`
Expected: no errors in new/modified files. (If the vendored `search-index.ts` `any` usage trips a rule other than `no-explicit-any`, the file-level disable already covers `no-explicit-any`; do not weaken types — add the specific rule to the disable comment if needed.)

- [ ] **Step 3: Build**

Run: `npm run build`
Expected: production build succeeds.

- [ ] **Step 4: Manual smoke (live session)**

Apply the migration to your Supabase project, then:
Run: `npm run dev`
- Sign in, start a session, say two related sentences that name an entity (e.g. "I had coffee with Maya about Project Atlas").
- In a later turn, reference it indirectly ("how's that project going?").
- Confirm in the browser devtools/network that the model issues a `get_relevant_memory` tool call and that the session continues normally (the agent should ground its reply without naming any machinery).

Expected: no console errors from `journal-memory`; the agent responds with continuity. (Retrieval makes no network request — it runs locally — so absence of a retrieval HTTP call is correct.)

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore: verification fixups for graphloop memory integration"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Read-side `retrieveMemory` over active-notebook `JournalState` → Tasks 7–8. ✓
- Separate `get_relevant_memory` tool → Task 9. ✓
- Durable provenance prerequisite → Tasks 1–2. ✓
- Vendored modules in `src/lib/graphloop/` + adapter → Tasks 3–8. ✓
- Lexical BM25 + Louvain fallback; embeddings dormant → Tasks 5–7 (embed vendored, never wired). ✓
- Deps `@orama/orama`, `graphology`, `graphology-communities-louvain` → Task 3. ✓
- Error handling / honesty (empty query, no-seed fallback, fail-closed) → Tasks 7–8 tests. ✓
- Tests ported + Lumen-specific → Tasks 1, 4–8. ✓
- Deferred (hybrid, cross-notebook, write-side swap) → not in any task, by design. ✓

**Type consistency:** `GraphState`/`Entity`/`Relation`/`GraphEntry` defined in Task 3 are used unchanged in Tasks 4–8; `retrieveMemory(state, query, notebookKey, opts?)` signature is identical in Task 8 (definition) and Task 9 (call site); `resetMemoryIndex()` defined Task 8, called Tasks 8–9; `journalEntryToRow`/`rowToEntry` defined Task 1, consumed Task 2.

**Placeholder scan:** No TBD/TODO; every code step contains complete, runnable content; the migration timestamp is a concrete filename.

# live-kg Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `live-kg` v0.1 — a standalone TS package that turns a stream of text utterances into a live, self-curating knowledge graph, with a framework-free core engine and optional React bindings.

**Architecture:** A `LiveGraphEngine` ingests text → extracts a `GraphPatch` via the Vercel AI SDK (`generateObject`, provider-neutral) → merges it into an in-memory `GraphState` with contradiction/self-heal handling → exposes a self-curating `Agenda` (thin/uncertain/bridge) and emits change events. Pure logic (`merge`, `agenda`, `noise`, `schema`) is fully unit-tested without a network; the AI call is tested with a mock model.

**Tech Stack:** TypeScript, Vercel AI SDK (`ai` v6 + Zod), `tsup` (build), `vitest` (test), React 18 (optional peer), `react-force-graph-2d` + `d3-force-3d` (optional, renderer only).

**Spec:** `docs/superpowers/specs/2026-06-11-live-kg-library-design.md`

**Origin (for ports):** the Lumen app at `/Users/trinabgoswamy/Documents/New project/echo-insights`. Port-source files are cited per task by absolute path.

**Conventions for all tasks:** new package root is the new repo's directory (referred to below as the repo root). All paths are relative to it. Run commands from the repo root. After each task, the listed test command must pass before committing.

---

## Task 0: Scaffold the package

**Files:**

- Create: `package.json`, `tsconfig.json`, `tsup.config.ts`, `vitest.config.ts`, `.gitignore`, `src/index.ts` (stub), `test/smoke.test.ts`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "live-kg",
  "version": "0.1.0",
  "description": "Live, self-curating knowledge graph engine for agents — built on the Vercel AI SDK.",
  "license": "MIT",
  "type": "module",
  "sideEffects": false,
  "files": ["dist"],
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.js",
      "require": "./dist/index.cjs"
    },
    "./react": {
      "types": "./dist/react/index.d.ts",
      "import": "./dist/react/index.js",
      "require": "./dist/react/index.cjs"
    },
    "./react/graph-view": {
      "types": "./dist/react/graph-view.d.ts",
      "import": "./dist/react/graph-view.js",
      "require": "./dist/react/graph-view.cjs"
    }
  },
  "scripts": {
    "build": "tsup",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit"
  },
  "peerDependencies": {
    "ai": "^6.0.0",
    "zod": "^3.23.0 || ^4.0.0",
    "react": ">=18",
    "react-dom": ">=18",
    "react-force-graph-2d": "^1.29.0",
    "d3-force-3d": "^3.0.0"
  },
  "peerDependenciesMeta": {
    "react": { "optional": true },
    "react-dom": { "optional": true },
    "react-force-graph-2d": { "optional": true },
    "d3-force-3d": { "optional": true }
  },
  "devDependencies": {
    "ai": "^6.0.168",
    "zod": "^3.23.8",
    "tsup": "^8.3.0",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0",
    "@types/react": "^18.3.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0",
    "@testing-library/react": "^16.0.0",
    "jsdom": "^25.0.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "jsx": "react-jsx",
    "strict": true,
    "declaration": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "noUncheckedIndexedAccess": true,
    "types": ["vitest/globals"]
  },
  "include": ["src", "test"]
}
```

- [ ] **Step 3: Create `tsup.config.ts`**

```ts
import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    index: "src/index.ts",
    "react/index": "src/react/index.ts",
    "react/graph-view": "src/react/graph-view.tsx",
  },
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  external: ["react", "react-dom", "react-force-graph-2d", "d3-force-3d", "ai", "zod"],
});
```

- [ ] **Step 4: Create `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    environmentMatchGlobs: [
      ["**/react/**", "jsdom"],
      ["**/*.tsx", "jsdom"],
    ],
  },
});
```

- [ ] **Step 5: Create `.gitignore`**

```
node_modules
dist
*.log
.DS_Store
```

- [ ] **Step 6: Create stub `src/index.ts` and `test/smoke.test.ts`**

`src/index.ts`:

```ts
export const VERSION = "0.1.0";
```

`test/smoke.test.ts`:

```ts
import { expect, test } from "vitest";
import { VERSION } from "../src/index";

test("package loads", () => {
  expect(VERSION).toBe("0.1.0");
});
```

- [ ] **Step 7: Install deps and verify tooling**

Run: `npm install && npm run test && npm run build`
Expected: smoke test PASS; `dist/` produced with `index.js`, `index.cjs`, `index.d.ts`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore: scaffold live-kg package (build, test, exports)"
```

---

## Task 1: Core domain types (`types.ts`)

**Files:**

- Create: `src/types.ts`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/lib/journal-types.ts`

- [ ] **Step 1: Create `src/types.ts`**

```ts
import type { LanguageModel } from "ai";
import type { ProviderOptions } from "ai";

export type EntityType =
  | "person"
  | "place"
  | "organization"
  | "project"
  | "event"
  | "activity"
  | "concept"
  | "emotion"
  | "other";

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

export type ExtractionMode = "wiki" | "granular";

export type IngestRole = "user" | "agent" | "source";

export interface ConversationTurn {
  role: IngestRole;
  text: string;
  createdAt: string;
}

export interface GraphPatch {
  entities: Array<{
    name: string;
    type: EntityType;
    description?: string;
    metadata?: Record<string, string>;
    questions?: string[];
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string>;
  }>;
  supersedes?: string[];
}

export interface Agenda {
  thinEntities: string[];
  justMentioned: string[];
  uncertainRelations: Array<{ source: string; label: string; target: string; score: number }>;
  bridgeCandidates: Array<[string, string]>;
  openQuestions: Array<{ entity: string; question: string }>;
  entityCount: number;
  relationCount: number;
}

export interface StorageAdapter {
  load(): Promise<GraphState | null>;
  save(state: GraphState): Promise<void>;
  clear?(): Promise<void>;
}

export interface EngineConfig {
  model: LanguageModel;
  mode?: ExtractionMode;
  storage?: StorageAdapter;
  prompts?: Partial<Record<ExtractionMode, string>>;
  maxContextEntities?: number;
  conversationWindow?: number;
  temperature?: number;
  providerOptions?: ProviderOptions;
  noiseNames?: Iterable<string>;
  onError?: (err: unknown) => void;
}

export const emptyState = (): GraphState => ({ entities: {}, relations: {}, entries: [] });
export const emptyPatch = (): GraphPatch => ({ entities: [], relations: [], supersedes: [] });
```

- [ ] **Step 2: Verify it typechecks**

Run: `npm run typecheck`
Expected: PASS (no errors).

- [ ] **Step 3: Commit**

```bash
git add src/types.ts
git commit -m "feat: core domain types (Entity, Relation, GraphState, GraphPatch, Agenda)"
```

---

## Task 2: Noise filter (`noise.ts`)

**Files:**

- Create: `src/noise.ts`, `test/noise.test.ts`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/lib/extract-graph.ts` (lines 541-606)

- [ ] **Step 1: Write the failing test (`test/noise.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { filterNoise, normalizeName } from "../src/noise";
import type { GraphPatch } from "../src/types";

describe("normalizeName", () => {
  test("lowercases and strips punctuation", () => {
    expect(normalizeName("Maya!")).toBe("maya");
    expect(normalizeName("  CS246 ")).toBe("cs246");
  });
});

describe("filterNoise", () => {
  test("drops pronoun/filler entities and relations pointing at them", () => {
    const patch: GraphPatch = {
      entities: [
        { name: "I", type: "person" },
        { name: "Maya", type: "person" },
        { name: "today", type: "other" },
      ],
      relations: [
        { source: "I", target: "Maya", label: "knows" },
        { source: "Maya", target: "Brooklyn", label: "in" },
      ],
      supersedes: ["r1"],
    };
    const out = filterNoise(patch);
    expect(out.entities.map((e) => e.name)).toEqual(["Maya"]);
    // "I" was dropped -> the I->Maya relation is dropped; Maya->Brooklyn kept
    // (Brooklyn references an existing/unknown entity, trusted cross-patch).
    expect(out.relations).toEqual([{ source: "Maya", target: "Brooklyn", label: "in" }]);
    expect(out.supersedes).toEqual(["r1"]);
  });

  test("respects extra noise names", () => {
    const patch: GraphPatch = { entities: [{ name: "Lumen", type: "other" }], relations: [] };
    expect(filterNoise(patch, new Set(["lumen"])).entities).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/noise.test.ts`
Expected: FAIL ("Cannot find module ../src/noise").

- [ ] **Step 3: Create `src/noise.ts`**

```ts
import type { GraphPatch } from "./types";

export const DEFAULT_NOISE_NAMES = new Set([
  "i",
  "me",
  "my",
  "mine",
  "you",
  "your",
  "yours",
  "we",
  "us",
  "our",
  "they",
  "them",
  "their",
  "today",
  "yesterday",
  "tomorrow",
  "morning",
  "afternoon",
  "evening",
  "night",
  "now",
  "later",
]);

export const normalizeName = (name: string): string =>
  name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9 ]+/g, "")
    .trim();

export const filterNoise = (patch: GraphPatch, extra?: Iterable<string>): GraphPatch => {
  const stop = new Set(DEFAULT_NOISE_NAMES);
  if (extra) for (const n of extra) stop.add(normalizeName(n));

  const kept = patch.entities.filter((e) => {
    const key = normalizeName(e.name);
    if (!key) return false;
    if (stop.has(key)) return false;
    if (key.length < 2) return false;
    return true;
  });
  const keptKeys = new Set(kept.map((e) => normalizeName(e.name)));
  const droppedKeys = new Set(
    patch.entities.map((e) => normalizeName(e.name)).filter((k) => !keptKeys.has(k)),
  );
  const relations = patch.relations.filter(
    (r) => !droppedKeys.has(normalizeName(r.source)) && !droppedKeys.has(normalizeName(r.target)),
  );
  return { entities: kept, relations, supersedes: patch.supersedes };
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/noise.test.ts`
Expected: PASS (4 assertions).

- [ ] **Step 5: Commit**

```bash
git add src/noise.ts test/noise.test.ts
git commit -m "feat: noise filter for extracted patches"
```

---

## Task 3: Merge reducer (`merge.ts`)

**Files:**

- Create: `src/merge.ts`, `test/merge.test.ts`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/lib/journal-store.ts` (`slugify` lines 40-48; `mergeExtraction` lines 291-443). De-journaled: drop `followUps`/`askedQuestions`; keep entities/relations/entries.

- [ ] **Step 1: Write the failing test (`test/merge.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { merge, slugify } from "../src/merge";
import { emptyState } from "../src/types";

describe("slugify", () => {
  test("normalizes names to ids", () => {
    expect(slugify("Project Atlas")).toBe("project-atlas");
    expect(slugify("CS246")).toBe("cs246");
  });
});

describe("merge", () => {
  test("adds new entities and relations, counts mentions", () => {
    const { next } = merge(emptyState(), "I ran with Maya", {
      entities: [
        { name: "Maya", type: "person" },
        { name: "running", type: "activity" },
      ],
      relations: [{ source: "running", target: "Maya", label: "with" }],
    });
    expect(next.entities["maya"].mentions).toBe(1);
    expect(next.relations["running__with__maya"].label).toBe("with");
    expect(next.entries).toHaveLength(1);
    expect(next.entries[0].entityIds).toContain("maya");
  });

  test("re-mention increments count and refreshes lastSeen", () => {
    const s1 = merge(emptyState(), "Maya", {
      entities: [{ name: "Maya", type: "person" }],
      relations: [],
    }).next;
    const s2 = merge(s1, "Maya again", {
      entities: [{ name: "Maya", type: "person" }],
      relations: [],
    }).next;
    expect(s2.entities["maya"].mentions).toBe(2);
  });

  test("supersede soft-deletes a relation; re-assertion self-heals it", () => {
    const s1 = merge(emptyState(), "Maya on Atlas", {
      entities: [
        { name: "Maya", type: "person" },
        { name: "Atlas", type: "project" },
      ],
      relations: [{ source: "Maya", target: "Atlas", label: "on" }],
    }).next;
    const rid = "maya__on__atlas";
    const s2 = merge(s1, "actually not", { entities: [], relations: [], supersedes: [rid] }).next;
    expect(s2.relations[rid].supersededAt).toBeTruthy();
    const s3 = merge(s2, "Maya is on Atlas after all", {
      entities: [
        { name: "Maya", type: "person" },
        { name: "Atlas", type: "project" },
      ],
      relations: [{ source: "Maya", target: "Atlas", label: "on" }],
    }).next;
    expect(s3.relations[rid].supersededAt).toBeUndefined();
  });

  test("merges questions, deduped, newest-first, capped at 8", () => {
    const { next } = merge(emptyState(), "Maya", {
      entities: [{ name: "Maya", type: "person", questions: ["q1", "q2", "q1"] }],
      relations: [],
    });
    expect(next.entities["maya"].questions).toEqual(["q1", "q2"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/merge.test.ts`
Expected: FAIL ("Cannot find module ../src/merge").

- [ ] **Step 3: Create `src/merge.ts`**

```ts
import type { Entity, GraphEntry, GraphPatch, GraphState, Relation } from "./types";

export function slugify(name: string): string {
  return (
    name
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 60) || `e-${Math.random().toString(36).slice(2, 8)}`
  );
}

const MAX_QUESTIONS_PER_ENTITY = 8;

const mergeQuestions = (
  existing: string[] | undefined,
  incoming: string[] | undefined,
): string[] | undefined => {
  if (!existing?.length && !incoming?.length) return existing;
  const seen = new Set<string>();
  const merged: string[] = [];
  for (const q of [...(incoming ?? []), ...(existing ?? [])]) {
    const trimmed = q?.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase().replace(/[^a-z0-9 ]+/g, "");
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(trimmed);
    if (merged.length >= MAX_QUESTIONS_PER_ENTITY) break;
  }
  return merged.length ? merged : undefined;
};

export function merge(
  prev: GraphState,
  text: string,
  patch: GraphPatch,
): { next: GraphState; entryId: string } {
  const now = new Date().toISOString();
  const entities: Record<string, Entity> = { ...prev.entities };
  const relations: Record<string, Relation> = { ...prev.relations };
  const entryEntityIds: string[] = [];
  const entryRelationIds: string[] = [];

  const nameToId: Record<string, string> = {};
  for (const e of patch.entities ?? []) {
    if (!e?.name) continue;
    const id = slugify(e.name);
    nameToId[e.name.toLowerCase()] = id;
    const existing = entities[id];
    entities[id] = existing
      ? {
          ...existing,
          description: e.description || existing.description,
          metadata: { ...existing.metadata, ...(e.metadata ?? {}) },
          mentions: existing.mentions + 1,
          lastSeen: now,
          type: existing.type === "other" ? e.type : existing.type,
          questions: mergeQuestions(existing.questions, e.questions),
        }
      : {
          id,
          name: e.name,
          type: e.type ?? "other",
          description: e.description,
          metadata: e.metadata ?? {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
          questions: mergeQuestions(undefined, e.questions),
        };
    entryEntityIds.push(id);
  }

  const explicitlyTaggedIds = new Set(Object.values(nameToId));

  for (const r of patch.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    if (!src || !tgt || src === tgt) continue;
    const rid = `${src}__${r.label}__${tgt}`;
    if (!relations[rid]) {
      relations[rid] = {
        id: rid,
        source: src,
        target: tgt,
        label: r.label,
        metadata: r.metadata ?? {},
        createdAt: now,
      };
    } else {
      const { supersededAt: _ignored, ...rest } = relations[rid];
      relations[rid] = { ...rest, metadata: { ...rest.metadata, ...(r.metadata ?? {}) } };
    }
    entryRelationIds.push(rid);
  }

  const implicitlyTouchedIds = new Set<string>();
  for (const r of patch.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    for (const id of [src, tgt]) {
      if (!id || explicitlyTaggedIds.has(id) || implicitlyTouchedIds.has(id)) continue;
      const existing = entities[id];
      if (!existing) continue;
      implicitlyTouchedIds.add(id);
      entities[id] = { ...existing, mentions: existing.mentions + 1, lastSeen: now };
      entryEntityIds.push(id);
    }
  }

  for (const id of patch.supersedes ?? []) {
    const target = relations[id];
    if (!target || target.supersededAt) continue;
    relations[id] = { ...target, supersededAt: now };
  }

  const entryId = `e-${Date.now()}`;
  const entry: GraphEntry = {
    id: entryId,
    text,
    createdAt: now,
    entityIds: Array.from(new Set(entryEntityIds)),
    relationIds: Array.from(new Set(entryRelationIds)),
  };

  return { next: { entries: [entry, ...prev.entries], entities, relations }, entryId };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/merge.test.ts`
Expected: PASS (6 assertions across 4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/merge.ts test/merge.test.ts
git commit -m "feat: pure merge reducer with supersede + self-heal"
```

---

## Task 4: Extraction schema (`schema.ts`)

**Files:**

- Create: `src/schema.ts`, `test/schema.test.ts`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/lib/extract-graph.ts` (lines 493-527)

- [ ] **Step 1: Write the failing test (`test/schema.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { graphPatchSchema } from "../src/schema";

describe("graphPatchSchema", () => {
  test("accepts a valid patch", () => {
    const r = graphPatchSchema.safeParse({
      entities: [{ name: "Maya", type: "person" }],
      relations: [{ source: "Maya", target: "Atlas", label: "on" }],
    });
    expect(r.success).toBe(true);
  });

  test("rejects an invalid entity type", () => {
    const r = graphPatchSchema.safeParse({
      entities: [{ name: "Maya", type: "alien" }],
      relations: [],
    });
    expect(r.success).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/schema.test.ts`
Expected: FAIL ("Cannot find module ../src/schema").

- [ ] **Step 3: Create `src/schema.ts`**

```ts
import { z } from "zod";

export const ENTITY_TYPES = [
  "person",
  "place",
  "organization",
  "project",
  "event",
  "activity",
  "concept",
  "emotion",
  "other",
] as const;

export const entityPatchSchema = z.object({
  name: z.string().min(1).describe("Entity name as it appears in the utterance."),
  type: z.enum(ENTITY_TYPES).describe("Named-entity category."),
  description: z.string().optional(),
  metadata: z.record(z.string(), z.string()).optional(),
  questions: z
    .array(z.string())
    .optional()
    .describe("Wiki-mode only: 2-4 lines of questioning to pursue about this entity."),
});

export const relationPatchSchema = z.object({
  source: z.string().min(1).describe("Source entity name."),
  target: z.string().min(1).describe("Target entity name."),
  label: z.string().min(1).describe("Snake_case verb phrase, e.g. works_with."),
  metadata: z.record(z.string(), z.string()).optional(),
});

export const graphPatchSchema = z.object({
  entities: z.array(entityPatchSchema),
  relations: z.array(relationPatchSchema),
  supersedes: z
    .array(z.string().min(1))
    .optional()
    .describe("Ids of existing relations the user just contradicted."),
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/schema.test.ts`
Expected: PASS (2 assertions).

- [ ] **Step 5: Commit**

```bash
git add src/schema.ts test/schema.test.ts
git commit -m "feat: Zod extraction schema for graph patches"
```

---

## Task 5: Extraction prompts (`prompts.ts`)

**Files:**

- Create: `src/prompts.ts`, `test/prompts.test.ts`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/lib/extract-graph.ts` (`WIKI_EXTRACTOR_PROMPT` lines 29-101; `GRANULAR_EXTRACTOR_PROMPT` lines 103-162). **De-brand:** remove all "Lumen" references and journal-specific framing; the prompts must read as a generic graph extractor.

- [ ] **Step 1: Write the failing test (`test/prompts.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { DEFAULT_PROMPTS } from "../src/prompts";

describe("DEFAULT_PROMPTS", () => {
  test("has both modes, non-empty, de-branded", () => {
    expect(DEFAULT_PROMPTS.wiki.length).toBeGreaterThan(200);
    expect(DEFAULT_PROMPTS.granular.length).toBeGreaterThan(200);
    expect(DEFAULT_PROMPTS.wiki).not.toMatch(/lumen/i);
    expect(DEFAULT_PROMPTS.granular).not.toMatch(/lumen/i);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/prompts.test.ts`
Expected: FAIL ("Cannot find module ../src/prompts").

- [ ] **Step 3: Create `src/prompts.ts`**

Port the two prompt strings from the port-source. Apply these exact de-branding transforms while copying:

- Replace every occurrence of `Lumen` with `the agent`.
- In the wiki prompt, replace "the user's personal wiki — built silently from their voice journal" with "a knowledge graph — built silently from a stream of text".
- Remove the line `- FAILS: "Lumen" — the agent's own name. Never extract.` (no longer applicable).
- Replace "voice journal" with "text stream" wherever it appears.
- Keep all extraction rules (the wiki-page test, relation density, supersedes, continuations) verbatim otherwise.

```ts
import type { ExtractionMode } from "./types";

export const WIKI_EXTRACTOR_PROMPT = `<<PASTE de-branded wiki prompt here>>`;
export const GRANULAR_EXTRACTOR_PROMPT = `<<PASTE de-branded granular prompt here>>`;

export const DEFAULT_PROMPTS: Record<ExtractionMode, string> = {
  wiki: WIKI_EXTRACTOR_PROMPT,
  granular: GRANULAR_EXTRACTOR_PROMPT,
};
```

> Implementer note: open the port-source file, copy each prompt template literal, apply the transforms above, and paste into the two constants. The `<<PASTE ...>>` placeholders MUST be replaced with the real, de-branded prompt text before Step 4 — the test asserts length > 200 and no "lumen".

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/prompts.test.ts`
Expected: PASS (4 assertions).

- [ ] **Step 5: Commit**

```bash
git add src/prompts.ts test/prompts.test.ts
git commit -m "feat: de-branded extraction prompts (wiki + granular)"
```

---

## Task 6: Agenda projection (`agenda.ts`)

**Files:**

- Create: `src/agenda.ts`, `test/agenda.test.ts`
- Port-source: `buildGraphSummary` in `/Users/trinabgoswamy/Documents/New project/echo-insights/src/routes/index.tsx` (lines 611-761). Generalized: coverage thresholds and bridge heuristic are defined explicitly below.

**Definitions locked for this task:**

- Word coverage: `description` word count + words across all `entries` whose `entityIds` include the entity. `thin` if `< 30`, `developing` if `< 100`, else `rich`.
- `uncertainRelations`: per active (non-superseded) relation, score 0-3: `+1` single-mention (relation id appears in ≤1 entry), `+1` cross-turn (source and target first appear in different entries), `+1` first-time pair (only one active relation between this source/target). Keep relations with score ≥ 2, top 3 by score.
- `bridgeCandidates`: entity pairs that share ≥1 common neighbor but have **no** direct active relation between them. Top 6, ordered by shared-neighbor count.
- `justMentioned`: entity names whose lowercased name is a substring of the most recent `conversation` user turn (or the latest entry text if no conversation).

- [ ] **Step 1: Write the failing test (`test/agenda.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { buildAgenda } from "../src/agenda";
import { merge } from "../src/merge";
import { emptyState } from "../src/types";

describe("buildAgenda", () => {
  test("classifies a one-mention entity as thin and surfaces open questions", () => {
    const { next } = merge(emptyState(), "Maya", {
      entities: [{ name: "Maya", type: "person", questions: ["How long have you known her?"] }],
      relations: [],
    });
    const agenda = buildAgenda(next, [
      { role: "user", text: "Maya", createdAt: new Date().toISOString() },
    ]);
    expect(agenda.thinEntities).toContain("Maya");
    expect(agenda.openQuestions).toEqual([
      { entity: "Maya", question: "How long have you known her?" },
    ]);
    expect(agenda.justMentioned).toContain("Maya");
    expect(agenda.entityCount).toBe(1);
  });

  test("flags a single fresh relation as uncertain (score >= 2)", () => {
    const { next } = merge(emptyState(), "Maya on Atlas", {
      entities: [
        { name: "Maya", type: "person" },
        { name: "Atlas", type: "project" },
      ],
      relations: [{ source: "Maya", target: "Atlas", label: "on" }],
    });
    const agenda = buildAgenda(next, []);
    expect(agenda.uncertainRelations[0]).toMatchObject({
      source: "Maya",
      label: "on",
      target: "Atlas",
    });
    expect(agenda.uncertainRelations[0].score).toBeGreaterThanOrEqual(2);
  });

  test("proposes a bridge between two entities sharing a neighbor but unlinked", () => {
    let s = emptyState();
    s = merge(s, "Maya on Atlas", {
      entities: [
        { name: "Maya", type: "person" },
        { name: "Atlas", type: "project" },
      ],
      relations: [{ source: "Maya", target: "Atlas", label: "on" }],
    }).next;
    s = merge(s, "Sam on Atlas", {
      entities: [
        { name: "Sam", type: "person" },
        { name: "Atlas", type: "project" },
      ],
      relations: [{ source: "Sam", target: "Atlas", label: "on" }],
    }).next;
    const agenda = buildAgenda(s, []);
    const pair = agenda.bridgeCandidates.map((p) => [...p].sort().join("+"));
    expect(pair).toContain(["maya", "sam"].sort().join("+"));
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/agenda.test.ts`
Expected: FAIL ("Cannot find module ../src/agenda").

- [ ] **Step 3: Create `src/agenda.ts`**

```ts
import type { Agenda, ConversationTurn, GraphState } from "./types";

const wordCount = (s: string | undefined): number =>
  s ? s.trim().split(/\s+/).filter(Boolean).length : 0;

export function buildAgenda(state: GraphState, conversation: ConversationTurn[]): Agenda {
  const entities = Object.values(state.entities);
  const activeRelations = Object.values(state.relations).filter((r) => !r.supersededAt);

  // coverage -> thin
  const wordsByEntity = new Map<string, number>();
  for (const e of entities) wordsByEntity.set(e.id, wordCount(e.description));
  for (const entry of state.entries) {
    for (const eid of entry.entityIds) {
      wordsByEntity.set(eid, (wordsByEntity.get(eid) ?? 0) + wordCount(entry.text));
    }
  }
  const thinEntities = entities
    .filter((e) => (wordsByEntity.get(e.id) ?? 0) < 30)
    .sort((a, b) => b.mentions - a.mentions)
    .map((e) => e.name);

  // justMentioned
  const lastUser =
    [...conversation].reverse().find((t) => t.role === "user") ?? [...conversation].reverse()[0];
  const probeText = (lastUser?.text ?? state.entries[0]?.text ?? "").toLowerCase();
  const justMentioned = entities
    .filter((e) => probeText.includes(e.name.toLowerCase()))
    .map((e) => e.name);

  // uncertainRelations
  const mentionCountByRelation = new Map<string, number>();
  const firstEntryByEntity = new Map<string, string>();
  for (const entry of state.entries) {
    for (const rid of entry.relationIds) {
      mentionCountByRelation.set(rid, (mentionCountByRelation.get(rid) ?? 0) + 1);
    }
    for (const eid of entry.entityIds) firstEntryByEntity.set(eid, entry.id);
  }
  const activePairCount = new Map<string, number>();
  for (const r of activeRelations) {
    const key = `${r.source} ${r.target}`;
    activePairCount.set(key, (activePairCount.get(key) ?? 0) + 1);
  }
  const uncertainRelations = activeRelations
    .map((r) => {
      let score = 0;
      if ((mentionCountByRelation.get(r.id) ?? 0) <= 1) score += 1;
      const se = firstEntryByEntity.get(r.source);
      const te = firstEntryByEntity.get(r.target);
      if (se && te && se !== te) score += 1;
      if ((activePairCount.get(`${r.source} ${r.target}`) ?? 0) <= 1) score += 1;
      return {
        source: state.entities[r.source]?.name,
        label: r.label,
        target: state.entities[r.target]?.name,
        score,
      };
    })
    .filter(
      (r): r is { source: string; label: string; target: string; score: number } =>
        r.score >= 2 && Boolean(r.source) && Boolean(r.target),
    )
    .sort((a, b) => b.score - a.score)
    .slice(0, 3);

  // bridgeCandidates: shared-neighbor, not directly linked
  const neighbors = new Map<string, Set<string>>();
  const directlyLinked = new Set<string>();
  for (const r of activeRelations) {
    if (!neighbors.has(r.source)) neighbors.set(r.source, new Set());
    if (!neighbors.has(r.target)) neighbors.set(r.target, new Set());
    neighbors.get(r.source)!.add(r.target);
    neighbors.get(r.target)!.add(r.source);
    directlyLinked.add([r.source, r.target].sort().join(" "));
  }
  const ids = [...neighbors.keys()];
  const bridges: Array<{ a: string; b: string; shared: number }> = [];
  for (let i = 0; i < ids.length; i++) {
    for (let j = i + 1; j < ids.length; j++) {
      const a = ids[i],
        b = ids[j];
      if (directlyLinked.has([a, b].sort().join(" "))) continue;
      const na = neighbors.get(a)!,
        nb = neighbors.get(b)!;
      let shared = 0;
      for (const n of na) if (nb.has(n)) shared++;
      if (shared > 0) bridges.push({ a, b, shared });
    }
  }
  const bridgeCandidates = bridges
    .sort((x, y) => y.shared - x.shared)
    .slice(0, 6)
    .map(
      (br) =>
        [state.entities[br.a]?.name ?? br.a, state.entities[br.b]?.name ?? br.b] as [
          string,
          string,
        ],
    );

  // openQuestions
  const openQuestions = entities
    .flatMap((e) => (e.questions ?? []).map((q) => ({ entity: e.name, question: q })))
    .slice(0, 12);

  return {
    thinEntities: thinEntities.slice(0, 10),
    justMentioned,
    uncertainRelations,
    bridgeCandidates,
    openQuestions,
    entityCount: entities.length,
    relationCount: activeRelations.length,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/agenda.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/agenda.ts test/agenda.test.ts
git commit -m "feat: self-curating agenda (thin/uncertain/bridge/openQuestions)"
```

---

## Task 7: Storage adapter (`storage.ts`)

**Files:**

- Create: `src/storage.ts`, `test/storage.test.ts`

- [ ] **Step 1: Write the failing test (`test/storage.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { InMemoryStorage } from "../src/storage";
import { emptyState } from "../src/types";

describe("InMemoryStorage", () => {
  test("returns null before save, round-trips after", async () => {
    const s = new InMemoryStorage();
    expect(await s.load()).toBeNull();
    const state = emptyState();
    state.entities["maya"] = {
      id: "maya",
      name: "Maya",
      type: "person",
      metadata: {},
      mentions: 1,
      firstSeen: "t",
      lastSeen: "t",
    };
    await s.save(state);
    expect((await s.load())?.entities["maya"].name).toBe("Maya");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/storage.test.ts`
Expected: FAIL ("Cannot find module ../src/storage").

- [ ] **Step 3: Create `src/storage.ts`**

```ts
import type { GraphState, StorageAdapter } from "./types";

export class InMemoryStorage implements StorageAdapter {
  private state: GraphState | null = null;
  async load(): Promise<GraphState | null> {
    return this.state ? structuredClone(this.state) : null;
  }
  async save(state: GraphState): Promise<void> {
    this.state = structuredClone(state);
  }
  async clear(): Promise<void> {
    this.state = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/storage.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/storage.ts test/storage.test.ts
git commit -m "feat: StorageAdapter interface + InMemoryStorage"
```

---

## Task 8: Provider-neutral extractor (`extractor.ts`)

**Files:**

- Create: `src/extractor.ts`, `test/extractor.test.ts`
- Port-source: `extract-graph.ts` `buildUserMessage` (lines 474-491). The Gemini `fetch` is replaced by AI SDK `generateObject` (verified against `node_modules/ai` v6.0.168).

- [ ] **Step 1: Write the failing test (`test/extractor.test.ts`)**

```ts
import { describe, expect, test } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { extract } from "../src/extractor";
import { DEFAULT_PROMPTS } from "../src/prompts";
import { emptyState } from "../src/types";

const mockReturning = (patch: unknown) =>
  new MockLanguageModelV3({
    doGenerate: async () => ({
      content: [{ type: "text", text: JSON.stringify(patch) }],
      finishReason: { unified: "stop", raw: undefined },
      usage: {
        inputTokens: { total: 10, noCache: 10, cacheRead: undefined, cacheWrite: undefined },
        outputTokens: { total: 20, text: 20, reasoning: undefined },
      },
      warnings: [],
    }),
  });

const baseArgs = {
  state: emptyState(),
  conversation: [],
  mode: "granular" as const,
  prompts: DEFAULT_PROMPTS,
  maxContextEntities: 30,
  temperature: 0.2,
};

describe("extract", () => {
  test("returns a noise-filtered patch from the model", async () => {
    const model = mockReturning({
      entities: [
        { name: "Maya", type: "person" },
        { name: "I", type: "person" },
      ],
      relations: [],
    });
    const patch = await extract({ ...baseArgs, text: "I met Maya", model });
    expect(patch.entities.map((e) => e.name)).toEqual(["Maya"]); // "I" filtered
  });

  test("returns empty patch on a recoverable model error", async () => {
    const model = new MockLanguageModelV3({
      doGenerate: async () => {
        throw new Error("safety block");
      },
    });
    const patch = await extract({ ...baseArgs, text: "anything", model });
    expect(patch).toEqual({ entities: [], relations: [], supersedes: [] });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/extractor.test.ts`
Expected: FAIL ("Cannot find module ../src/extractor").

- [ ] **Step 3: Create `src/extractor.ts`**

```ts
import { generateObject, type LanguageModel, type ProviderOptions } from "ai";
import { filterNoise } from "./noise";
import { graphPatchSchema } from "./schema";
import {
  emptyPatch,
  type ConversationTurn,
  type ExtractionMode,
  type GraphPatch,
  type GraphState,
} from "./types";

export interface ExtractArgs {
  text: string;
  state: GraphState;
  conversation: ConversationTurn[];
  model: LanguageModel;
  mode: ExtractionMode;
  prompts: Record<ExtractionMode, string>;
  maxContextEntities: number;
  temperature: number;
  providerOptions?: ProviderOptions;
  noiseNames?: Iterable<string>;
  signal?: AbortSignal;
}

const buildUserMessage = (args: ExtractArgs): string => {
  const existing = Object.values(args.state.entities).slice(0, args.maxContextEntities);
  const existingList = existing.length
    ? existing
        .map((e) => `- ${e.name} (${e.type})${e.description ? ` - ${e.description}` : ""}`)
        .join("\n")
    : "(none yet)";
  const recent = args.conversation.slice(-4);
  const recentList = recent.length
    ? recent.map((t) => `- ${t.role}: ${t.text}`).join("\n")
    : "(none)";
  return `EXISTING ENTITIES (reuse these spellings for the same thing):
${existingList}

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these):
${recentList}

NEW UTTERANCE:
"""${args.text}"""`;
};

export async function extract(args: ExtractArgs): Promise<GraphPatch> {
  const text = args.text?.trim();
  if (!text || text.length < 2) return emptyPatch();

  try {
    const { object } = await generateObject({
      model: args.model,
      schema: graphPatchSchema,
      system: args.prompts[args.mode],
      prompt: buildUserMessage(args),
      temperature: args.temperature,
      abortSignal: args.signal,
      providerOptions: args.providerOptions,
    });
    return filterNoise(object as GraphPatch, args.noiseNames);
  } catch (err) {
    // Re-throw aborts so the engine can ignore superseded calls; swallow
    // recoverable failures (safety blocks, occasional schema misses) by
    // returning an empty patch rather than breaking the whole graph.
    if (err instanceof Error && err.name === "AbortError") throw err;
    return emptyPatch();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/extractor.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/extractor.ts test/extractor.test.ts
git commit -m "feat: provider-neutral extractor via AI SDK generateObject"
```

---

## Task 9: The engine (`engine.ts`)

**Files:**

- Create: `src/engine.ts`, `test/engine.test.ts`
- Port-source: `processGraphUpdate` control logic in `index.tsx` (lines 545-604) — abort/supersede + merge + emit.

- [ ] **Step 1: Write the failing test (`test/engine.test.ts`)**

```ts
import { describe, expect, test, vi } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { LiveGraphEngine } from "../src/engine";

const mockReturning = (patch: unknown) =>
  new MockLanguageModelV3({
    doGenerate: async () => ({
      content: [{ type: "text", text: JSON.stringify(patch) }],
      finishReason: { unified: "stop", raw: undefined },
      usage: {
        inputTokens: { total: 1, noCache: 1, cacheRead: undefined, cacheWrite: undefined },
        outputTokens: { total: 1, text: 1, reasoning: undefined },
      },
      warnings: [],
    }),
  });

describe("LiveGraphEngine", () => {
  test("ingest extracts, merges, and emits onChange", async () => {
    const engine = new LiveGraphEngine({
      model: mockReturning({
        entities: [{ name: "Maya", type: "person" }],
        relations: [],
      }),
    });
    const onChange = vi.fn();
    engine.onChange(onChange);
    await engine.ingest("I met Maya today", { role: "user" });

    expect(engine.getState().entities["maya"].name).toBe("Maya");
    expect(onChange).toHaveBeenCalledOnce();
    expect(engine.getAgenda().entityCount).toBe(1);
  });

  test("hydrate loads prior state from storage", async () => {
    const first = new LiveGraphEngine({
      model: mockReturning({ entities: [{ name: "Atlas", type: "project" }], relations: [] }),
    });
    await first.ingest("Atlas is live", { role: "user" });
    const saved = first.getStorage();

    const second = new LiveGraphEngine({
      model: mockReturning({ entities: [], relations: [] }),
      storage: saved,
    });
    await second.hydrate();
    expect(second.getState().entities["atlas"].name).toBe("Atlas");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/engine.test.ts`
Expected: FAIL ("Cannot find module ../src/engine").

- [ ] **Step 3: Create `src/engine.ts`**

```ts
import { buildAgenda } from "./agenda";
import { extract } from "./extractor";
import { merge } from "./merge";
import { DEFAULT_PROMPTS } from "./prompts";
import { InMemoryStorage } from "./storage";
import {
  emptyState,
  type Agenda,
  type ConversationTurn,
  type EngineConfig,
  type ExtractionMode,
  type GraphState,
  type IngestRole,
  type StorageAdapter,
} from "./types";

export class LiveGraphEngine {
  private state: GraphState = emptyState();
  private conversation: ConversationTurn[] = [];
  private listeners = new Set<(s: GraphState) => void>();
  private inFlight: AbortController | null = null;

  private readonly model;
  private mode: ExtractionMode;
  private readonly storage: StorageAdapter;
  private readonly prompts: Record<ExtractionMode, string>;
  private readonly maxContextEntities: number;
  private readonly conversationWindow: number;
  private readonly temperature: number;
  private readonly providerOptions;
  private readonly noiseNames?: Iterable<string>;
  private readonly onError?: (err: unknown) => void;

  constructor(config: EngineConfig) {
    this.model = config.model;
    this.mode = config.mode ?? "granular";
    this.storage = config.storage ?? new InMemoryStorage();
    this.prompts = { ...DEFAULT_PROMPTS, ...(config.prompts ?? {}) };
    this.maxContextEntities = config.maxContextEntities ?? 30;
    this.conversationWindow = config.conversationWindow ?? 8;
    this.temperature = config.temperature ?? 0.2;
    this.providerOptions = config.providerOptions;
    this.noiseNames = config.noiseNames;
    this.onError = config.onError;
  }

  getState(): GraphState {
    return this.state;
  }
  getAgenda(): Agenda {
    return buildAgenda(this.state, this.conversation);
  }
  getStorage(): StorageAdapter {
    return this.storage;
  }
  setMode(mode: ExtractionMode) {
    this.mode = mode;
  }

  onChange(cb: (s: GraphState) => void): () => void {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private emit() {
    for (const cb of this.listeners) cb(this.state);
  }

  async hydrate(): Promise<void> {
    const loaded = await this.storage.load();
    if (loaded) {
      this.state = loaded;
      this.emit();
    }
  }

  abort() {
    this.inFlight?.abort();
    this.inFlight = null;
  }

  reset() {
    this.abort();
    this.state = emptyState();
    this.conversation = [];
    void this.storage.save(this.state);
    this.emit();
  }

  async ingest(text: string, opts: { role?: IngestRole } = {}): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;
    const role = opts.role ?? "source";
    this.conversation.push({ role, text: trimmed, createdAt: new Date().toISOString() });
    if (this.conversation.length > this.conversationWindow) {
      this.conversation = this.conversation.slice(-this.conversationWindow);
    }

    this.inFlight?.abort();
    const controller = new AbortController();
    this.inFlight = controller;

    try {
      const patch = await extract({
        text: trimmed,
        state: this.state,
        conversation: this.conversation,
        model: this.model,
        mode: this.mode,
        prompts: this.prompts,
        maxContextEntities: this.maxContextEntities,
        temperature: this.temperature,
        providerOptions: this.providerOptions,
        noiseNames: this.noiseNames,
        signal: controller.signal,
      });
      if (controller.signal.aborted) return;
      this.state = merge(this.state, trimmed, patch).next;
      await this.storage.save(this.state);
      this.emit();
    } catch (err) {
      if (err instanceof Error && err.name === "AbortError") return;
      this.onError?.(err);
    } finally {
      if (this.inFlight === controller) this.inFlight = null;
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/engine.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/engine.ts test/engine.test.ts
git commit -m "feat: LiveGraphEngine — ingest, abort/supersede, agenda, persistence"
```

---

## Task 10: Core barrel (`index.ts`)

**Files:**

- Modify: `src/index.ts`

- [ ] **Step 1: Replace `src/index.ts` with the public barrel**

```ts
export { LiveGraphEngine } from "./engine";
export { merge, slugify } from "./merge";
export { buildAgenda } from "./agenda";
export { extract } from "./extractor";
export { filterNoise, normalizeName, DEFAULT_NOISE_NAMES } from "./noise";
export { graphPatchSchema, entityPatchSchema, relationPatchSchema, ENTITY_TYPES } from "./schema";
export { DEFAULT_PROMPTS, WIKI_EXTRACTOR_PROMPT, GRANULAR_EXTRACTOR_PROMPT } from "./prompts";
export { InMemoryStorage } from "./storage";
export { emptyState, emptyPatch } from "./types";
export type {
  Entity,
  Relation,
  GraphEntry,
  GraphState,
  GraphPatch,
  Agenda,
  EntityType,
  ExtractionMode,
  IngestRole,
  ConversationTurn,
  StorageAdapter,
  EngineConfig,
} from "./types";

export const VERSION = "0.1.0";
```

- [ ] **Step 2: Update `test/smoke.test.ts` to assert the public API exists**

```ts
import { expect, test } from "vitest";
import { LiveGraphEngine, merge, buildAgenda, InMemoryStorage, VERSION } from "../src/index";

test("public API is exported", () => {
  expect(typeof LiveGraphEngine).toBe("function");
  expect(typeof merge).toBe("function");
  expect(typeof buildAgenda).toBe("function");
  expect(typeof InMemoryStorage).toBe("function");
  expect(VERSION).toBe("0.1.0");
});
```

- [ ] **Step 3: Run full test suite + typecheck**

Run: `npm run test && npm run typecheck`
Expected: all tests PASS; typecheck clean.

- [ ] **Step 4: Commit**

```bash
git add src/index.ts test/smoke.test.ts
git commit -m "feat: core public API barrel"
```

---

## Task 11: React hook (`react/use-live-graph.ts`)

**Files:**

- Create: `src/react/use-live-graph.ts`, `test/use-live-graph.test.tsx`
- Port-source: state-mirror pattern in `/Users/trinabgoswamy/Documents/New project/echo-insights/src/hooks/use-gemini-live.ts` (minus all audio).

- [ ] **Step 1: Write the failing test (`test/use-live-graph.test.tsx`)**

```tsx
import { describe, expect, test } from "vitest";
import { act, render, screen } from "@testing-library/react";
import { MockLanguageModelV3 } from "ai/test";
import { useLiveGraph } from "../src/react/use-live-graph";

const model = new MockLanguageModelV3({
  doGenerate: async () => ({
    content: [
      {
        type: "text",
        text: JSON.stringify({ entities: [{ name: "Maya", type: "person" }], relations: [] }),
      },
    ],
    finishReason: { unified: "stop", raw: undefined },
    usage: {
      inputTokens: { total: 1, noCache: 1, cacheRead: undefined, cacheWrite: undefined },
      outputTokens: { total: 1, text: 1, reasoning: undefined },
    },
    warnings: [],
  }),
});

function Probe() {
  const { state, ingest } = useLiveGraph({ model });
  return (
    <div>
      <button onClick={() => void ingest("I met Maya", { role: "user" })}>go</button>
      <span data-testid="count">{Object.keys(state.entities).length}</span>
    </div>
  );
}

describe("useLiveGraph", () => {
  test("ingest updates mirrored state", async () => {
    render(<Probe />);
    expect(screen.getByTestId("count").textContent).toBe("0");
    await act(async () => {
      screen.getByText("go").click();
    });
    expect(screen.getByTestId("count").textContent).toBe("1");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/use-live-graph.test.tsx`
Expected: FAIL ("Cannot find module ../src/react/use-live-graph").

- [ ] **Step 3: Create `src/react/use-live-graph.ts`**

```ts
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { LiveGraphEngine } from "../engine";
import {
  emptyState,
  type Agenda,
  type EngineConfig,
  type GraphState,
  type IngestRole,
} from "../types";
import { buildAgenda } from "../agenda";

export interface UseLiveGraph {
  state: GraphState;
  agenda: Agenda;
  ingest: (text: string, opts?: { role?: IngestRole }) => Promise<void>;
  status: "idle" | "extracting";
  error: unknown;
  reset: () => void;
}

export function useLiveGraph(config: EngineConfig): UseLiveGraph {
  // Engine is created once; config is read through a ref so prop changes
  // don't tear down the session.
  const configRef = useRef(config);
  configRef.current = config;

  const engine = useMemo(
    () => new LiveGraphEngine({ ...configRef.current, onError: (e) => setError(e) }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const [state, setState] = useState<GraphState>(emptyState());
  const [status, setStatus] = useState<"idle" | "extracting">("idle");
  const [error, setError] = useState<unknown>(null);

  useEffect(() => engine.onChange(setState), [engine]);

  const ingest = useCallback(
    async (text: string, opts?: { role?: IngestRole }) => {
      setStatus("extracting");
      try {
        await engine.ingest(text, opts);
      } finally {
        setStatus("idle");
      }
    },
    [engine],
  );

  const reset = useCallback(() => engine.reset(), [engine]);
  const agenda = useMemo(() => buildAgenda(state, []), [state]);

  return { state, agenda, ingest, status, error, reset };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/use-live-graph.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/react/use-live-graph.ts test/use-live-graph.test.tsx
git commit -m "feat: useLiveGraph React hook"
```

---

## Task 12: React renderer (`react/graph-view.tsx`)

**Files:**

- Create: `src/react/graph-view.tsx`, `test/graph-view.test.tsx`
- Port-source: `/Users/trinabgoswamy/Documents/New project/echo-insights/src/components/graph-view.tsx` (1058 lines). This is a **mechanical copy** with import rewrites.

- [ ] **Step 1: Copy the source file**

Copy the entire contents of the port-source into `src/react/graph-view.tsx`, then apply these exact edits:

1. Replace `import type { Entity, Relation, EntityType } from "@/lib/journal-types";` with `import type { Entity, Relation, EntityType } from "../types";`
2. Replace `import { cn } from "@/lib/utils";` with a local helper at the top of the file:
   ```ts
   const cn = (...parts: Array<string | false | null | undefined>) =>
     parts.filter(Boolean).join(" ");
   ```
   and delete the original `cn` import.
3. Leave the `react-force-graph-2d` and `d3-force-3d` imports unchanged.
4. Ensure the public component(s) used by consumers are exported with `export` (at minimum `GraphView`; also `GraphLegend`, `GraphMinimap` if present in the source).

- [ ] **Step 2: Write a smoke test (`test/graph-view.test.tsx`)**

```tsx
import { describe, expect, test, vi } from "vitest";
import { render } from "@testing-library/react";
import { GraphView } from "../src/react/graph-view";

// react-force-graph-2d needs canvas/WebGL not present in jsdom — stub it.
vi.mock("react-force-graph-2d", () => ({ default: () => null }));

describe("GraphView", () => {
  test("renders without crashing given entities + relations", () => {
    const entities = [
      {
        id: "maya",
        name: "Maya",
        type: "person" as const,
        metadata: {},
        mentions: 1,
        firstSeen: "t",
        lastSeen: "t",
      },
    ];
    const relations: never[] = [];
    const { container } = render(<GraphView entities={entities} relations={relations} />);
    expect(container).toBeTruthy();
  });
});
```

> Implementer note: if the source `GraphView` requires props beyond `entities`/`relations` (e.g. `highlightId`, `activeEntityIds`), make them optional in the component's props interface during the copy, defaulting to `undefined`/`[]`, so the smoke test and library consumers aren't forced to pass them. Adjust the test to pass any prop the component cannot default.

- [ ] **Step 3: Run test + typecheck**

Run: `npx vitest run test/graph-view.test.tsx && npm run typecheck`
Expected: PASS; typecheck clean.

- [ ] **Step 4: Commit**

```bash
git add src/react/graph-view.tsx test/graph-view.test.tsx
git commit -m "feat: GraphView renderer (ported, de-coupled from app types)"
```

---

## Task 13: React barrel + full build (`react/index.ts`)

**Files:**

- Create: `src/react/index.ts`

- [ ] **Step 1: Create `src/react/index.ts`**

```ts
export { useLiveGraph } from "./use-live-graph";
export type { UseLiveGraph } from "./use-live-graph";
```

> Note: `GraphView` is intentionally NOT re-exported here — it lives on its own subpath (`live-kg/react/graph-view`) so the hook stays free of the force-graph dependency.

- [ ] **Step 2: Build all three entries**

Run: `npm run build`
Expected: `dist/index.*`, `dist/react/index.*`, `dist/react/graph-view.*` (js, cjs, d.ts each) all produced, no errors.

- [ ] **Step 3: Run the full suite + typecheck**

Run: `npm run test && npm run typecheck`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/react/index.ts
git commit -m "feat: react subpath barrel; full multi-entry build"
```

---

## Task 14: README + packaging verification

**Files:**

- Create: `README.md`, `LICENSE`

- [ ] **Step 1: Create `LICENSE`** (MIT, current year, your name).

- [ ] **Step 2: Create `README.md`** with: one-line pitch, install (`npm i live-kg ai @ai-sdk/google zod`), the core quickstart and the React quickstart from the spec §5, a provider table (note any AI SDK provider works), and the v0.1 scope/non-goals.

- [ ] **Step 3: Verify the published surface**

Run: `npm pack --dry-run`
Expected: the tarball includes `dist/` with all three entry points and their `.d.ts` files; `src/` and `test/` are excluded (per `files: ["dist"]`).

- [ ] **Step 4: Commit**

```bash
git add README.md LICENSE
git commit -m "docs: README + MIT license"
```

---

## Self-Review (completed during plan authoring)

- **Spec coverage:** engine (T9), extractor/AI-SDK (T8), merge+supersede (T3), agenda (T6), storage (T7), types (T1), schema (T4), prompts (T5), noise (T2), React hook (T11), GraphView (T12), subpath exports + build (T0/T13), README (T14). All spec §4–§9 items map to a task. Voice/examples correctly absent (non-goals).
- **Placeholder scan:** one intentional `<<PASTE ...>>` in Task 5 with an explicit, testable replacement instruction (length>200, no "lumen") — not a silent placeholder. Task 12 is a mechanical copy with exact edits, not a placeholder.
- **Type consistency:** `GraphPatch`/`GraphState`/`Agenda`/`EngineConfig` defined in T1 and used unchanged in T3/T6/T8/T9; `merge` returns `{ next, entryId }` everywhere; `extract(args)` signature matches its call in `engine.ts`; mock-model `usage`/`finishReason` shape matches AI SDK v6 (verified in `node_modules/ai`).

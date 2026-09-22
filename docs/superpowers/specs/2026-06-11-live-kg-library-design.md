# Design: `live-kg` — a live, self-curating knowledge-graph engine for agents

- **Date:** 2026-06-11
- **Status:** Draft (awaiting user review)
- **Author:** Trinab (with Claude)
- **Origin:** Extracted from the Lumen voice-journal app (`echo-insights`). This spec seeds a _separate_ open-source repo; `live-kg` is a placeholder name.

---

## 1. Summary

A TypeScript library that turns a stream of text utterances into a **live, incrementally-built knowledge graph** — and, critically, exposes a **self-curating agenda** that tells a calling agent what the graph does not yet know. Built on the Vercel AI SDK so any provider/model plugs in with a single argument.

The differentiator versus static "extract-to-graph" tools: a closed feedback loop. The graph's own gaps and low-confidence edges are surfaced as an agenda, which an agent reads to decide its next question, whose answer flows back into the graph.

```
ingest(text) ─► extractor (AI SDK generateObject) ─► GraphPatch
                                                        │
                       abort/supersede stale calls      ▼
                                          merge reducer ─► GraphState ─► onChange()
                                                        │
                                          buildAgenda() ─► Agenda (thin / uncertain / bridges)
                                                        │
                       agent reads agenda ─► asks better question ─► ingest(...)  ⟲
```

## 2. Goals / Non-goals

### Goals (v0.1)

- Framework-free **core engine** that ingests text, extracts entities + relations, and maintains a graph with contradiction handling.
- **Provider-neutral** extraction via the Vercel AI SDK (`LanguageModel` + `generateObject`).
- **Self-curating agenda** as a first-class API (`getAgenda()`).
- **Pluggable storage** via a `StorageAdapter` interface; in-memory default.
- **React bindings:** a `useLiveGraph` hook and a default `GraphView` renderer, shipped behind subpath exports so non-React users never pull them.
- Pure, well-tested merge + agenda logic (no LLM needed to test them).

### Non-goals (v0.1 — deferred to v0.2+)

- Voice / realtime-audio adapter (the Gemini Live stack stays in the origin app).
- Persistence backends beyond in-memory (users supply their own `StorageAdapter`).
- Auth, Obsidian/markdown export, notebooks/sessions (app-specific in the origin).
- Bindings for frameworks other than React (Vue/Svelte).
- Streaming/partial extraction (`streamObject`) — v0.1 extracts per completed utterance.
- A custom-ontology authoring UI (the entity-type set is overridable via config, but ships with a default ontology).

## 3. Background — what is being extracted from the origin app

| Origin (echo-insights)                                                 | Becomes (live-kg)                                        | Transformation                                                                                                 |
| ---------------------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `src/lib/extract-graph.ts` (Gemini REST, hand-rolled function calling) | `extractor.ts` + `schema.ts` + `prompts.ts` + `noise.ts` | Replace Gemini `fetch` plumbing with AI SDK `generateObject`; de-brand prompts; keep Zod schema + noise filter |
| `src/lib/journal-store.ts` → `mergeExtraction`, `slugify`              | `merge.ts`                                               | Lift the pure reducer out; drop Supabase I/O (moves behind `StorageAdapter`)                                   |
| `src/lib/journal-types.ts`                                             | `types.ts`                                               | Keep `Entity`/`Relation`/`EntityType`; drop `Notebook`, journal-only fields                                    |
| `buildGraphSummary` (in `src/routes/index.tsx`)                        | `agenda.ts`                                              | Lift the planner snapshot out of the React route into a pure function                                          |
| `processGraphUpdate` control logic (abort/supersede) (in `index.tsx`)  | `engine.ts`                                              | Becomes the engine's `ingest()` orchestration                                                                  |
| `src/hooks/use-gemini-live.ts` (React state mirroring)                 | `react/use-live-graph.ts`                                | Keep the engine-lifecycle + state-mirror pattern; drop all audio/WebSocket                                     |
| `src/components/graph-view.tsx`                                        | `react/graph-view.tsx`                                   | Swap `journal-types` imports for `live-kg` types; otherwise as-is                                              |
| `src/lib/gemini-live-client.ts`, audio worklets, pcm-player            | —                                                        | Dropped from v0.1 (v0.2 voice package)                                                                         |

## 4. Architecture

### 4.1 Core engine (`LiveGraphEngine`)

A stateful orchestrator that owns the graph and the extraction lifecycle.

- `ingest(text, opts?)` — extract from `text` (with graph context), abort any in-flight extraction, merge the resulting patch, persist via storage, emit `onChange`.
- `getState()` — current `GraphState`.
- `getAgenda()` — compute the agenda from current state (pure call into `agenda.ts`).
- `onChange(cb)` — subscribe to state changes; returns an unsubscribe function.
- `hydrate()` — load prior state from the storage adapter (e.g., on app start).
- `reset()` / `abort()` — clear state / cancel in-flight extraction.

The engine also maintains a **bounded recent-conversation buffer** (role-tagged turns, default last ~8) used as pronoun-resolution context for the extractor and as input to `buildAgenda` (for `justMentioned` / probed detection). This buffer is ephemeral and engine-owned — it is _not_ part of the persisted `GraphState`. `ingest(text, opts?)` accepts `{ role?: "user" | "agent" | "source" }` to tag each turn; `role` defaults to `"source"` for non-conversational ingestion (docs, logs).

**Abort/supersede.** Each `ingest` aborts the previous in-flight extraction via an `AbortController`. A newer utterance carries strictly more context, so the older call is wasted; only the latest writes to state. (Ported from `processGraphUpdate`.)

### 4.2 Extraction (`extractor.ts`)

Provider-neutral. Builds a system prompt (mode-specific) + a user message containing the new utterance plus a slim graph context (top-N existing entities, recent conversation for pronoun resolution), then calls:

```ts
const { object } = await generateObject({
  model, // AI SDK LanguageModel passed by the user
  schema: graphPatchSchema, // Zod
  system: systemPrompt,
  prompt: userMessage,
  temperature: 0.2,
  abortSignal: signal,
});
```

`generateObject` handles structured output across providers, so the hand-rolled Gemini `function_declarations` / `tool_config` / response-unwrapping in the origin disappears. Output is re-validated by Zod (defense in depth) and noise-filtered before return. Recoverable failures (safety blocks, validation misses) return an empty patch rather than throwing; auth failures throw.

### 4.3 Merge (`merge.ts`)

Pure reducer: `merge(state, text, patch) → { next, ... }`. Slugifies names to ids, dedupes against existing entities, bumps mention counts, appends an entry to the utterance log, and applies `supersedes` (soft-delete via `supersededAt`) with the self-heal path (re-asserting a superseded relation clears the timestamp). No side effects → trivially unit-testable.

### 4.4 Agenda (`agenda.ts`)

Pure projection: `buildAgenda(state, conversation, opts) → Agenda`. Computes:

- `thinEntities` — entities below a word-coverage threshold, ranked by mentions.
- `justMentioned` — entities named in the latest utterance.
- `uncertainRelations` — relations scored 0–3 on three structural signals (single-mention, cross-turn endpoints, first-time pair); those scoring ≥2 surface.
- `bridgeCandidates` — entity pairs the graph suggests could be linked.
- `openQuestions` — the per-entity question backlog (populated in `wiki` mode).

### 4.5 Storage (`storage.ts`)

```ts
interface StorageAdapter {
  load(): Promise<GraphState | null>;
  save(state: GraphState): Promise<void>;
  clear?(): Promise<void>;
}
```

Default: `InMemoryStorage`. Users implement the interface for Supabase/Postgres/localStorage/file.

### 4.6 React bindings

- `react/use-live-graph.ts` — `useLiveGraph(config)` instantiates and holds a `LiveGraphEngine` (stable across renders), subscribes to `onChange`, mirrors `state` + `agenda` into React state, exposes `ingest`, `status`, `error`, `reset`. (Ported from `use-gemini-live`'s lifecycle/state-mirror pattern, minus audio.)
- `react/graph-view.tsx` — `GraphView` force-directed renderer. Depends on `react-force-graph-2d` + `d3-force-3d`. Shipped on its **own subpath** so the lightweight hook does not drag in the viz libraries.

## 5. Public API

### Core

```ts
import { LiveGraphEngine } from "live-kg";
import { google } from "@ai-sdk/google";

const engine = new LiveGraphEngine({
  model: google("gemini-3-flash"), // any AI SDK model
  mode: "granular", // "wiki" | "granular" (default "granular")
  // storage: new InMemoryStorage(), // default
  // prompts: { wiki, granular },    // optional overrides
  // entityTypes: [...],             // optional ontology override
  // maxContextEntities: 30,         // existing entities shipped to the extractor
  // onError: (e) => {},
});

const unsubscribe = engine.onChange((state) => render(state));
await engine.ingest("I went running with Maya in Brooklyn.", { role: "user" });
const agenda = engine.getAgenda();
```

### React — hook (`live-kg/react`)

```tsx
const { state, agenda, ingest, status, error, reset } = useLiveGraph({
  model: openai("gpt-5"),
  mode: "wiki",
});
```

### React — renderer (`live-kg/react/graph-view`)

```tsx
import { GraphView } from "live-kg/react/graph-view";
<GraphView entities={Object.values(state.entities)} relations={Object.values(state.relations)} />;
```

## 6. Data model (`types.ts`)

```ts
type EntityType =
  | "person"
  | "place"
  | "organization"
  | "project"
  | "event"
  | "activity"
  | "concept"
  | "emotion"
  | "other"; // default ontology; overridable

interface Entity {
  id: string;
  name: string;
  type: EntityType;
  description?: string;
  metadata: Record<string, string | number | boolean>;
  mentions: number;
  firstSeen: string;
  lastSeen: string;
  questions?: string[]; // wiki-mode backlog
}

interface Relation {
  id: string;
  source: string;
  target: string;
  label: string;
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  supersededAt?: string;
}

interface GraphEntry {
  id: string;
  text: string;
  createdAt: string;
  entityIds: string[];
  relationIds: string[];
}

interface GraphState {
  entities: Record<string, Entity>;
  relations: Record<string, Relation>;
  entries: GraphEntry[];
}

interface GraphPatch {
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

interface Agenda {
  thinEntities: string[];
  justMentioned: string[];
  uncertainRelations: Array<{ source: string; label: string; target: string; score: number }>;
  bridgeCandidates: Array<[string, string]>;
  openQuestions: Array<{ entity: string; question: string }>;
  entityCount: number;
  relationCount: number;
}
```

## 7. File manifest

```
live-kg/
├── package.json              # exports map (. , ./react, ./react/graph-view); peerDeps below
├── tsconfig.json
├── tsup.config.ts            # 3 entries (core, react hook, graph-view); esm+cjs+dts
├── vitest.config.ts
├── eslint.config.js · .prettierrc · .prettierignore
├── README.md · LICENSE (MIT)
├── .github/workflows/ci.yml  # typecheck + lint + test on push/PR
├── src/
│   ├── index.ts              # core barrel
│   ├── engine.ts             # LiveGraphEngine: ingest, abort/supersede, getAgenda, onChange, hydrate
│   ├── extractor.ts          # provider-neutral generateObject extraction
│   ├── prompts.ts            # wiki + granular system prompts (de-branded, overridable)
│   ├── schema.ts             # Zod GraphPatch schemas
│   ├── merge.ts              # pure merge reducer + slugify + supersede/self-heal
│   ├── agenda.ts             # buildAgenda — the self-curating read loop
│   ├── noise.ts              # default stoplist + filterNoise + normalizeName
│   ├── storage.ts            # StorageAdapter interface + InMemoryStorage
│   ├── types.ts              # Entity, Relation, GraphState, GraphPatch, Agenda, EngineConfig
│   └── react/
│       ├── index.ts          # exports useLiveGraph
│       ├── use-live-graph.ts # engine lifecycle + React state mirror
│       └── graph-view.tsx    # force-graph renderer
└── test/
    ├── merge.test.ts         # dedupe, supersede, self-heal, mention counts (pure)
    ├── agenda.test.ts        # thin classification, uncertainRelations scoring (pure)
    └── extractor.test.ts     # prompt assembly + noise filter + error→empty, via a mock LanguageModel
```

## 8. Packaging & build

- **Single package**, subpath exports:
  ```jsonc
  "exports": {
    ".":                  { "types": "./dist/index.d.ts",            "import": "./dist/index.js",            "require": "./dist/index.cjs" },
    "./react":            { "types": "./dist/react/index.d.ts",      "import": "./dist/react/index.js",      "require": "./dist/react/index.cjs" },
    "./react/graph-view": { "types": "./dist/react/graph-view.d.ts", "import": "./dist/react/graph-view.js", "require": "./dist/react/graph-view.cjs" }
  }
  ```
- **peerDependencies:** `ai` (Vercel AI SDK), `zod`.
- **Optional peers** (`peerDependenciesMeta: { optional: true }`): `react`, `react-dom`, `react-force-graph-2d`, `d3-force-3d`.
- Users install their provider package themselves (`@ai-sdk/google`, `@ai-sdk/openai`, …).
- **Build:** `tsup` (ESM + CJS + `.d.ts`). **Test:** `vitest`. Lint/format conventions mirror the origin repo (ESLint + Prettier).

## 9. Testing strategy

- `merge.ts` and `agenda.ts` are pure → exhaustively unit-tested with no LLM: dedupe, supersede + self-heal, mention counts, thin/uncertain/bridge classification.
- `extractor.ts` tested against a **mock `LanguageModel`** (the AI SDK supports injecting a fake model) to assert prompt assembly, schema validation, noise filtering, and the recoverable-error → empty-patch path — deterministic, no network.
- No live-network tests in CI.

## 10. Open questions / future (v0.2+)

- **Voice package** — a `live-kg/voice` adapter wrapping the Gemini Live client, so transcripts feed `ingest()` automatically.
- **Export plugins** — Obsidian/markdown export as an optional module.
- **Other-framework bindings** — Vue/Svelte equivalents of `useLiveGraph`.
- **Custom ontology** — first-class typed ontology configuration (beyond the v0.1 default-set override).
- **Streaming extraction** — `streamObject` for partial entity pop-in mid-utterance.

## 11. Decisions captured during brainstorming

1. **Scope:** core engine + React bindings (voice deferred).
2. **Provider:** build on the Vercel AI SDK only (free, open-source; user pays only their chosen provider for tokens).
3. **Packaging:** single package + subpath exports (graduates to a monorepo later without a rewrite).
4. **Examples:** omitted from v0.1.
5. **React split:** lightweight hook (`/react`) separated from the heavy force-graph renderer (`/react/graph-view`).

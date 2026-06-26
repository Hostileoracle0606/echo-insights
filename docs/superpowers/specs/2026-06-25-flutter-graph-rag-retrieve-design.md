# Flutter — Graph-RAG Retrieve & Select (Read-Side Parity) — Design Spec

**Date:** 2026-06-25
**Status:** Approved (design), pending implementation plan
**Author:** brainstormed with Claude
**Scope:** echo-insights Flutter iOS port (`lib/`). Brings the read-side memory retrieval the web app
gained in [2026-06-17-lumen-graphloop-memory-design.md](2026-06-17-lumen-graphloop-memory-design.md)
(which explicitly scoped the Flutter port *out*) to the Flutter app.

---

## 1. Context & Motivation

The web app and the Flutter port share the same two-branch AI pipeline (conversation via Gemini Live,
silent graph extraction via Gemini REST) and the same agenda/"select" logic. But they diverge on the
**read-side**:

- **Web app** registers *two* private Gemini Live tools:
  - `get_graph_summary` — the *agenda* ("what to ask next": thin entities, bridges, uncertain relations).
  - `get_relevant_memory` — *retrieval* ("what past memory is relevant now"), backed by the graphloop
    `retrieve()` pipeline in [src/lib/graphloop/retrieve.ts](../../../src/lib/graphloop/retrieve.ts), wired
    through [src/lib/journal-memory.ts](../../../src/lib/journal-memory.ts).
- **Flutter app** registers *only* `get_graph_summary` (the "select" half, ported as
  [lib/logic/agenda.dart](../../../lib/logic/agenda.dart) +
  [lib/providers/journal_provider.dart](../../../lib/providers/journal_provider.dart)). There is **no
  retrieval** — no BM25 seed search, no k-hop expansion, no `get_relevant_memory` tool, no `graphloop`
  import anywhere under `lib/`.

The product consequence: on Flutter the agent can ask smart follow-ups but cannot recall specific past
context on demand. When the user says *"remember that thing about Maya last week?"*, the web agent fires
`get_relevant_memory("Maya")` and grounds its reply in the retrieved subgraph; the Flutter agent has only
whatever the full entity list in `get_graph_summary` happens to contain.

### Why an edge function, not a Dart port

graphloop is TypeScript built on Orama (a JS BM25/vector engine). Reimplementing BM25 + k-hop + the
multi-signal ranking natively in Dart would create a **second source of truth** that drifts from the web
scoring over time. Instead we run the *existing, unmodified* graphloop `retrieve()` inside a Supabase
edge function and have Flutter call it. Zero scoring drift; the web and Flutter agents recall identically.

---

## 2. Goals / Non-Goals

### Goals

- Give the Flutter voice agent a `get_relevant_memory({ query })` tool with behaviour identical to the web
  app's, by reusing the web app's graphloop `retrieve()` verbatim server-side.
- Match web retrieval freshness: retrieval must see entities extracted seconds ago, before the debounced
  Supabase save lands.
- Fail closed: any retrieval failure returns empty context so a recall failure never breaks the live turn.
- Port the `get_relevant_memory` prompt guidance into the Flutter system instruction, preserving the
  "never read aloud / never mention retrieval" guardrails verbatim.

### Non-Goals

- **No embeddings / hybrid mode.** Lexical-only (`mode: "lexical"`), matching web's
  `retrieveMemory` ([src/lib/journal-memory.ts:62](../../../src/lib/journal-memory.ts)).
- **No Dart reimplementation** of any graphloop algorithm.
- **No write-side changes.** Extraction, merge, and agenda are untouched.
- **No multi-notebook scope.** Phase 1 = the active notebook only, mirroring web Phase 1.
- **No server-side persistence of retrieval state.** The graph travels in the request body (see §4).

---

## 3. Architecture & Data Flow

```
Flutter (live session)                Supabase Edge Fn              graphloop (TS, reused as-is)
─────────────────────                 ────────────────────          ───────────────────────────
LLM emits get_relevant_memory(query)
   │
   ├─ journal_provider onToolCall
   │     RetrieveMemoryService.retrieve(
   │        query, state)
   │       └ functions.invoke(
   │           'retrieve-memory',
   │           { query, state })  ─────►  verify JWT (cloned preamble)
   │                                      GraphState from body
   │                                      SearchIndex.sync(entities)
   │                                      buildCommunities(g)
   │                                      retrieve(g, q, {lexical}) ──► BM25 seeds → k-hop
   │                                                                     → rank → packContext
   │     { context: "## Entities…" } ◄──  return RetrievalResult
   │
   └─ return { context } to Gemini Live → LLM grounds its reply
```

This is the web app's `retrieveMemory()` → `retrieve()` path relocated to the server, with `GraphState`
arriving over the wire instead of from browser memory.

---

## 4. Design Decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Retrieval engine | **Supabase edge function** wrapping existing TS graphloop | Zero scoring drift vs. web; reuses code verbatim |
| Graph source | **Sent in request body** (live `JournalState`) | Only option matching web freshness — recall sees entities extracted before the 2s debounced save |
| Retrieval mode | **Lexical-only** | Matches web `retrieveMemory`; no `ai`/embedding runtime dependency |
| graphloop → Deno | **Import map** (`deno.json`) aliasing bare specifiers to esm.sh | Orama is pure JS; only resolution plumbing is needed (see §6) |
| Failure mode | **Fail closed → empty context** | A recall failure must never break the live turn |

---

## 5. The Three Surfaces

### 5.1 Edge function — `supabase/functions/retrieve-memory/index.ts` (new)

- Clones the auth / CORS / OPTIONS / notebook-ownership preamble from
  [supabase/functions/extract-graph/index.ts:340–389](../../../supabase/functions/extract-graph/index.ts)
  verbatim.
- Imports the **existing** `src/lib/graphloop` source as the single source of truth — `retrieve`,
  `SearchIndex`, `buildCommunities`. (Resolution: relative import up the tree if the Supabase bundler
  reaches it; fallback is a `supabase/functions/_shared/graphloop` copy — decided empirically in the build
  step, see §8 step 2.)
- Request body: `{ query: string, state: { entities, relations, entries } }`.
- Handler: `SearchIndex.sync(entities)` → `buildCommunities(g)` → `retrieve(g, query, { mode: "lexical" }, { index, communities })`.
- Response: the graphloop `RetrievalResult` (`{ context, entities, relations, entries, seeds }`) — same
  shape the web returns. The Flutter client only consumes `context`, but returning the full shape keeps
  parity and aids debugging.

### 5.2 Flutter service — `lib/services/retrieve_memory_service.dart` (new)

- `Future<String> retrieve({ required String query, required JournalState state })`.
- Calls `_client.functions.invoke('retrieve-memory', body: {...})`; `functions.invoke` auto-attaches the
  Supabase session JWT, so no manual auth wiring.
- Serializes `JournalState` to the graphloop field shape — entities, relations, entries only; drops
  `followUps` / `askedQuestions`, exactly like web's `toGraphState`
  ([src/lib/journal-memory.ts:20](../../../src/lib/journal-memory.ts)).
- Fail-closed wrapper: any exception or error response → returns `""`.

### 5.3 Flutter wiring — `conversation_policy.dart` + `journal_provider.dart`

- Register a second tool `get_relevant_memory` alongside `get_graph_summary` in the tools list
  ([lib/providers/journal_provider.dart:235](../../../lib/providers/journal_provider.dart)).
- Extend the `onToolCall` switch ([lib/providers/journal_provider.dart:251](../../../lib/providers/journal_provider.dart))
  to route `get_relevant_memory` → `RetrieveMemoryService`, returning `{ context }`.
- Port the `get_relevant_memory` prompt block from
  [src/lib/conversation-policy.ts:311](../../../src/lib/conversation-policy.ts) into
  `geminiLiveSystemInstruction` ([lib/logic/conversation_policy.dart:18](../../../lib/logic/conversation_policy.dart)),
  preserving the "never read aloud / never mention memory or the graph" guardrails verbatim.

---

## 6. The Deno Resolution Wrinkle

graphloop uses bare npm specifiers that Node resolves via `node_modules` but Deno cannot:

```ts
import { create, search } from "@orama/orama";  // search-index.ts — value import
import type { EmbeddingModel } from "ai";          // retrieve.ts — type-only, erased at runtime
```

This is a **resolution plumbing** problem, not a compatibility problem. Orama is pure JavaScript and runs
in Deno once Deno can *find* it. The fix is a `deno.json` import map redirecting the two bare specifiers to
esm.sh. The `ai` import is type-only and, because we run lexical mode, never invoked at runtime — the line
erases. `retrieve.ts` value-imports `./embed`, so `embed.ts` is loaded but never called; if its own `ai`
import fails to resolve at load time, step 3 will make that import lazy or stub it.

---

## 7. Testing

- **Edge function (Deno test):** fixture `GraphState` → assert seeds → k-hop expansion → packed `context`
  contains the expected entities/relations. Assert empty query → empty result.
- **Dart unit test:** `JournalState` → graphloop-body serialization parity (entity/relation/entry field
  shapes match what `retrieve()` expects; followUps/askedQuestions dropped).
- **Manual E2E:** live session — reference something from earlier, confirm the agent recalls grounded
  detail and does **not** mention the tool/graph; then disable the function and confirm graceful
  degradation (no crash, conversation continues).

---

## 8. Sequential Build Steps

1. **Scaffold the edge function** — clone `extract-graph`'s shell (auth, CORS, OPTIONS, ownership check);
   stub body parse + empty response.
2. **Bridge graphloop into Deno** — add `deno.json` import map for `@orama/orama` + `ai`; import
   `retrieve`, `SearchIndex`, `buildCommunities`. Decide up-the-tree relative import vs. `_shared` copy by
   testing the bundle.
3. **Implement retrieval** — parse `{ query, state }` → `SearchIndex.sync` → `buildCommunities` →
   `retrieve` → return `RetrievalResult`. Deno-test with a fixture graph.
4. **Deploy & smoke-test** — `supabase functions deploy retrieve-memory`; curl with a real JWT.
5. **Dart service** — `RetrieveMemoryService` + serialization + fail-closed wrapper. Unit-test serialization.
6. **Register the tool** — add `get_relevant_memory` declaration in `conversation_policy.dart`.
7. **Port the prompt** — add the `get_relevant_memory` guidance block to `geminiLiveSystemInstruction`.
8. **Wire the handler** — extend `onToolCall` in `journal_provider.dart` to call the service.
9. **End-to-end test** — live recall + fail-closed path.

---

## 9. Risks

- **Orama-in-Deno via esm.sh** — verified pure-JS, low risk; step 2 proves the bundle.
- **Payload size for large notebooks** — acceptable for Phase 1 (single active notebook); revisit if graphs
  grow large (e.g. server-side DB load + recent-turn patch).
- **Prompt-port fidelity** — the guardrails ("never read aloud", "never mention memory/the graph") must be
  carried verbatim or the agent leaks the mechanism.

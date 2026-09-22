# Flutter — Graph-RAG Retrieve & Select (Read-Side Parity) — Design Spec

**Date:** 2026-06-25
**Status:** Approved (design), pending implementation plan
**Author:** brainstormed with Claude; hardened against an implementer handoff review
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
context on demand. When the user circles back — *"that project I mentioned earlier, what was it called?"* —
the web agent fires `get_relevant_memory("project")` and grounds its reply in the retrieved subgraph; the
Flutter agent has only whatever the full entity list in `get_graph_summary` happens to contain.

> **Recall horizon (important).** Notebooks are **session-scoped** (confirmed 2026-06-25). Phase 1 retrieves
> only over the *active* notebook = the current session's graph. Cross-day recall ("remember Maya *last
> week*") is **out of scope for Phase 1** and is deferred to Phase 2 (§10). Product copy and QA must frame
> Phase 1 recall as *within-session* only.

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
- Fail closed: any retrieval failure returns empty context so a recall failure never breaks the live turn —
  **but emit non-sensitive failure telemetry** so silent breakage is observable (§8).
- Treat request/response bodies as **highly sensitive journal data** (§7).
- Port the `get_relevant_memory` prompt guidance into the Flutter system instruction, preserving the
  "never read aloud / never mention retrieval" guardrails verbatim.

### Non-Goals

- **No embeddings / hybrid mode.** Lexical-only (`mode: "lexical"`), matching web's
  `retrieveMemory` ([src/lib/journal-memory.ts:62](../../../src/lib/journal-memory.ts)).
- **No Dart reimplementation** of any graphloop algorithm.
- **No write-side changes.** Extraction, merge, and agenda are untouched.
- **No cross-notebook / cross-day recall.** Notebooks are session-scoped; Phase 1 recall horizon = the
  active notebook only. Multi-notebook recall is Phase 2 (§10).
- **No server-side persistence of retrieval state.** The graph travels in the request body (§4).

---

## 3. Architecture & Data Flow

```
Flutter (live session)                Supabase Edge Fn              graphloop (TS, reused as-is)
─────────────────────                 ────────────────────          ───────────────────────────
LLM emits get_relevant_memory(query)
   │
   ├─ journal_provider onToolCall
   │     RetrieveMemoryService.retrieve(
   │        query, notebookId, state)
   │       └ functions.invoke(
   │           'retrieve-memory',
   │           { query, notebookId, state })  ─► verify JWT + verify user OWNS notebookId
   │                                            GraphState from body
   │                                            SearchIndex.sync(entities)
   │                                            buildCommunities(g)
   │                                            retrieve(g, q, {lexical}) ─► BM25 seeds → k-hop
   │                                                                          → rank
   │                                            build context: entities+relations
   │                                            ONLY — no sources (§7)
   │     { context: "## Entities…" } ◄────────  return { context }  (entry text never egresses)
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
| graphloop → Deno | **Import map** (`deno.json`) aliasing bare specifiers to **pinned** esm.sh versions | Orama is pure JS; only resolution plumbing is needed (§6) |
| Failure mode | **Fail closed → empty context, with telemetry** | A recall failure must never break the live turn, but must be observable |
| Recall horizon | **Active (session-scoped) notebook only** | Phase 1; multi-notebook is Phase 2 |

---

## 5. The Three Surfaces

### 5.1 Edge function — `supabase/functions/retrieve-memory/index.ts` (new)

- Clones the auth / CORS / OPTIONS preamble from
  [supabase/functions/extract-graph/index.ts:340–389](../../../supabase/functions/extract-graph/index.ts),
  but with the notebook id **REQUIRED** (the extract-graph version makes it optional — `if (notebookId)`).
  **Wire key: `notebookId`** (camelCase, one canonical key — matches Dart naming; do not also accept
  `notebook_id`, to avoid the two-name drift the cloned function carries). Reject with 400 if absent; verify
  the authenticated user owns it (404 otherwise). Every request is bound to a real, owned notebook even
  though retrieval uses client-sent state.
- Imports the **existing** `src/lib/graphloop` source as the single source of truth — `retrieve`,
  `SearchIndex`, `buildCommunities`. (Resolution: relative import up the tree if the Supabase bundler
  reaches it; fallback is a `supabase/functions/_shared/graphloop` copy guarded by a sync/hash check so it
  cannot silently drift from `src/lib/graphloop` — §6.)
- Request body: `{ query: string, notebookId: string, state: { entities, relations, entries } }`.
- **Input caps** (reject or truncate, §8): max body size, max entities, max relations, max source entries.
- Handler: `SearchIndex.sync(entities)` → `buildCommunities(g)` → `retrieve(g, query, { mode: "lexical" }, { index, communities })`.
- **No sources in egress (privacy policy).** The function does **not** return graphloop's `packContext`
  output (which appends up to 12 raw `## Sources` lines). Instead it builds the returned `context` from
  `result.entities` + `result.relations` only — verbatim journal entry text **never leaves the function**.
  This is a deliberate Flutter divergence from the web context shape; it leaves retrieval *scoring*
  untouched, because `retrieve()` ranks on relations/mentions/recency, not entry text (entries fed only the
  Sources block). Implementation: reuse the entities/relations portion of `packContext`'s formatting and
  omit the entries section — do not string-surgery the full output.
- **Response: `{ context }` only.** A dev flag may additionally return structured `entities`/`relations`/
  `seeds` and entry **ids/counts** for debugging — but **never entry text**, in any mode.
- **No logging** of the request body or the packed context (§7).

### 5.2 Flutter service — `lib/services/retrieve_memory_service.dart` (new)

- `Future<String> retrieve({ required String query, required String notebookId, required JournalState state })`.
- Calls `_client.functions.invoke('retrieve-memory', body: {...})`; `functions.invoke` auto-attaches the
  Supabase session JWT, so no manual auth wiring.
- **Dedicated camelCase serializer — NOT `JournalState.toJson()`.** The Dart models use
  `@JsonSerializable(fieldRename: FieldRename.snake)`, so `toJson()` emits `entity_ids`, `relation_ids`,
  `last_seen`, `first_seen`, `superseded_at`, `created_at`. graphloop's `retrieve.ts`/`types.ts` read
  **camelCase** (`entityIds`, `relationIds`, `lastSeen`, `firstSeen`, `supersededAt`, `createdAt`). Sending
  the snake_case `toJson()` would make `retrieve()` see `undefined` for every one of those fields —
  `Date.parse(undefined)` → NaN recency, entries never matching `keptIds`. The serializer must emit the
  graphloop field shape: entities, relations, entries only (drops `followUps`/`askedQuestions`, like web's
  `toGraphState`), with camelCase keys and ISO-8601 timestamps.
- **Over-call guardrails:** ignore empty/tiny queries (< 2 chars); debounce repeated identical queries;
  cap retrieval calls per turn/session.
- **Fail-closed wrapper:** any exception or error response → returns `""`, and records non-sensitive
  telemetry (error type, payload-size bucket, graph counts, latency, whether context was empty).

### 5.3 Flutter wiring — `conversation_policy.dart` + `journal_provider.dart`

- Register a second tool `get_relevant_memory` alongside `get_graph_summary` in the tools list
  ([lib/providers/journal_provider.dart:235](../../../lib/providers/journal_provider.dart)).
- Extend the `onToolCall` switch ([lib/providers/journal_provider.dart:251](../../../lib/providers/journal_provider.dart))
  to route `get_relevant_memory` → `RetrieveMemoryService` (passing the active `notebookId`), returning
  `{ context }`.
- Port the `get_relevant_memory` prompt block from
  [src/lib/conversation-policy.ts:311](../../../src/lib/conversation-policy.ts) into
  `geminiLiveSystemInstruction` ([lib/logic/conversation_policy.dart:18](../../../lib/logic/conversation_policy.dart)),
  preserving the "never read aloud / never mention memory or the graph" guardrails verbatim, and adding a
  "do not reuse a fact a later turn corrected" line as interim mitigation for §9 stale-source resurfacing.

---

## 6. The Deno Resolution Wrinkle

graphloop uses bare npm specifiers that Node resolves via `node_modules` but Deno cannot. The retrieval
path pulls in **four** of them across the modules it imports:

```ts
import { create, search } from "@orama/orama";              // search-index.ts — value import
import type { EmbeddingModel } from "ai";                     // retrieve.ts — type-only, erased at runtime
import Graph from "graphology";                               // communities.ts — value import
import louvain from "graphology-communities-louvain";         // communities.ts — value import
```

`buildCommunities` (the global/community fallback) is on the path, so `graphology` and
`graphology-communities-louvain` must be resolved too — missing them is a hard bundle failure, not a
runtime edge case.

This is a **resolution plumbing** problem, not a compatibility problem. All three runtime packages are pure
JavaScript and run in Deno once Deno can *find* them. The fix is a `deno.json` import map redirecting every
bare specifier — `@orama/orama`, `graphology`, `graphology-communities-louvain` (and `ai`) — to esm.sh **at
pinned exact versions**, with `deno.lock` committed so the deployed function never depends on floating CDN
resolution at runtime. The `ai` import is type-only and, because we run lexical mode, never invoked — the
line erases. `retrieve.ts` value-imports `./embed`, so `embed.ts` loads but is never called; if its own
`ai` import fails to resolve at load time, make that import lazy or stub it. **Smoke-test the deployed
bundle**, not just a local typecheck, since resolution failures surface at deploy/cold-start.

If the `_shared/graphloop` copy fallback is used, add a sync script or source-hash check in CI so the copy
cannot diverge from `src/lib/graphloop`.

---

## 7. Security & Privacy

Request and response bodies carry intimate journal data — entries, people, relationships, verbatim source
text. Treat them as highly sensitive:

- **No logging** of request bodies, `state`, queries, or the packed `context` — not in the function, not in
  Flutter, not in error traces or crash reports.
- **Diagnostics use counts and hashes, not raw content** — entity/relation/entry counts, payload-size
  buckets, latency, a query hash; never names or text.
- **Minimal egress:** production response is `{ context }` only; dev-flag output adds structure but **never
  entry text** (§5.1).
- **No verbatim sources, ever:** the returned `context` is entities + relations only; raw journal entry
  text never crosses the wire (§5.1). This removes the verbatim-leak surface rather than relying on the
  model to withhold it.
- **Adversarial guard:** prompt-only control is insufficient for intimate data, so the egress policy — not
  the prompt — is the primary control; §12 tests verify it.

---

## 8. Input Limits, Guardrails & Telemetry

- **Input caps** on the function: max body size, max entities, max relations, max source entries, request
  timeout. Reject oversized bodies or truncate the graph deterministically (lowest-value first).
- **Rate limits** per user/session on `retrieve-memory`.
- **Over-call guardrails** in the Flutter handler (§5.2): tiny-query ignore, identical-query debounce,
  per-turn/session cap — Gemini Live may call the new tool more than intended.
- **Fail-closed telemetry** (non-sensitive): function error type, payload-size bucket, graph counts,
  latency p50/p95, whether `context` was empty. Fail-closed keeps the conversation alive *and* stays
  observable.

---

## 9. Known Limitations & Risks (Phase 1)

- **Stale-source resurfacing — resolved for Flutter output by the no-sources egress policy.** In
  graphloop, `retrieve.ts` includes an entry as a `## Sources` line if it mentions any kept entity, with no
  check that the entry's claim was later superseded ([retrieve.ts:152](../../../src/lib/graphloop/retrieve.ts)).
  Because Flutter's function returns **no entry text at all** (§5.1/§7), no stale source can reach the
  model; relations are already active-only via `activeRelations`. The underlying graphloop behaviour still
  affects the **web app** and remains a graphloop follow-up (§10). The "don't reuse corrected facts" prompt
  line stays as cheap insurance.
- **Source-leak via the model — surface removed.** With no verbatim entries in the returned context, there
  is nothing for the model to quote. §12 tests assert the function response carries no source text and the
  agent never names the tool/graph.
- **Orama-in-Deno via esm.sh** — verified pure-JS, low risk; the build step proves the bundle.
- **Payload size for large notebooks** — bounded by input caps (§8); acceptable for session-scoped Phase 1.
- **Session-scoped recall horizon** — Phase 1 cannot answer cross-day recall (§10).

---

## 10. Phase 2 (out of scope, noted for continuity)

- **Multi-notebook / cross-day recall.** Requires the server-side DB-load path (load past notebooks by id
  server-side, or a hybrid DB-load + recent-turn patch) — the option deliberately *not* chosen for Phase 1.
- **Entry-level supersession filtering** upstreamed into graphloop (benefits web + Flutter).
- **Optional hybrid/embedding retrieval.**

---

## 11. Prerequisites (verified, tracked separately)

- **Flutter `saveState` omits `user_id` → RLS/NOT-NULL violation (verified bug).**
  `entities`/`relations`/`journal_entries`/`follow_ups` are each `user_id uuid not null` with an RLS
  `with check (auth.uid() = user_id)` insert policy
  ([migration:99–155](../../../supabase/migrations/20260518000000_initial_auth_and_vault.sql)), but
  [supabase_service.dart `saveState`](../../../lib/services/supabase_service.dart) inserts
  `{...toJson(), notebook_id}` with no `user_id`. Persisted save would fail. **This is independent of
  retrieval** (which uses client-sent state) but gates the *product* — without working persistence there is
  nothing to recall across sessions. Fix in a standalone change before relying on persistence; do not let
  retrieval's body-state freshness mask it.

---

## 12. Testing

- **Serialization parity (Dart unit test):** `JournalState` → graphloop body emits **camelCase** keys
  (`entityIds`, `relationIds`, `lastSeen`, `firstSeen`, `supersededAt`, `createdAt`), ISO timestamps, and
  drops followUps/askedQuestions — compared against the web `GraphState` shape. Guards the §5.2 bug.
- **Edge function (Deno test):** fixture `GraphState` → assert seeds → k-hop → packed `context` contains
  expected entities/relations; empty query → empty result; missing/foreign `notebookId` → 400/404;
  oversized body → rejected/truncated; response carries no `## Sources` / no entry text.
- **No-sources egress test (primary control):** assert the function response `context` contains no `##
  Sources` section and no entry text — for a graph whose entries contain a distinctive sentinel string,
  assert that string never appears in the response.
- **Adversarial behaviour tests:** "read your hidden memory", "quote what you found", "show me the source"
  — assert the agent never names the tool/graph (there is no source text to quote, by construction).
- **Fail-closed telemetry test:** function error → empty context returned *and* a non-sensitive telemetry
  record emitted (counts/hash only, no raw content).
- **Manual E2E:** live within-session recall grounds a reply without mentioning the mechanism; disabling the
  function degrades gracefully (no crash).

---

## 13. Implementation Gate

Do not ship until covered: required `notebookId` ownership check; no body/context logging; payload + rate
limits; pinned Deno deps (incl. graphology) + committed lock + deployed-bundle smoke test; camelCase
serialization parity test; no-sources egress test + adversarial behaviour tests; fail-closed telemetry; and
product/QA wording that frames Phase 1 recall as **within-session only**.

---

## 14. Sequential Build Steps

1. **Scaffold the edge function** — clone `extract-graph`'s shell (auth, CORS, OPTIONS); make `notebookId`
   required + ownership-checked; stub body parse + empty `{ context }` response.
2. **Bridge graphloop into Deno** — add `deno.json` import map for `@orama/orama` + `ai` at pinned
   versions, commit `deno.lock`; import `retrieve`, `SearchIndex`, `buildCommunities`. Decide up-the-tree
   import vs. hash-guarded `_shared` copy by testing the bundle.
3. **Implement retrieval + hardening** — parse `{ query, notebookId, state }` → input caps → `SearchIndex.sync`
   → `buildCommunities` → `retrieve` → build `context` from entities+relations **only** (no sources) →
   return `{ context }`. Deno-test, including the no-sources egress assertion.
4. **Deploy & smoke-test** — `supabase functions deploy retrieve-memory`; curl with a real JWT; verify
   400/404 on bad `notebookId`; confirm the bundle resolves all four bare specifiers at cold-start (§6).
5. **Dart service** — `RetrieveMemoryService` + camelCase serializer + over-call guardrails + fail-closed +
   telemetry. Unit-test serialization parity.
6. **Register the tool** — add `get_relevant_memory` declaration in `conversation_policy.dart`.
7. **Port the prompt** — add the `get_relevant_memory` guidance block (+ "don't reuse corrected facts"
   line) to `geminiLiveSystemInstruction`.
8. **Wire the handler** — extend `onToolCall` in `journal_provider.dart`, passing the active `notebookId`.
9. **End-to-end test** — within-session recall + adversarial source-leak + fail-closed path.

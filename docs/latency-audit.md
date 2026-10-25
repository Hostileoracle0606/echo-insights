# Latency audit

Audited on `main` at `e80a6fb` (2026-10-24). This covers everything between a user's action and what they see or hear: the iPhone app, Supabase (Postgres, PostgREST, auth, the `retrieve-memory` edge function), the AWS runtime (API Gateway, the authorizer, the Lambdas) and the two Gemini APIs.

Every number below carries one of four labels:

| Label | Meaning |
|---|---|
| **measured** | Timed by a test in this branch, on a MacBook (host VM or local Docker). Expect an iPhone to be 2–4× slower for app-side CPU. |
| **constant** | A wait written into the code, pinned by `test/perf/latency_budget_test.dart`. |
| **hops** | A count of network calls made one after another, from tests that make every fake dependency take a fixed time. Real time = hops × that hop's round trip. |
| **estimate** | Not measurable here: phone networks, cold starts, Gemini's own speed. Shown as a range, with its assumption. `scripts/latency/probe-staging.mjs` and `scripts/latency/voice-timing-report.mjs` replace these with real numbers. |

## The short version

1. **Every `get_graph_summary` tool answer lists the whole notebook.** **Measured:** about 6,200 tokens at 200 entities and 31,000 tokens at 1,000, and 13 ms to 231 ms of CPU to build on this Mac. Gemini has to read all of it before it can reply, on every call.
2. **Every user turn uploads the whole notebook to `retrieve-memory` before extraction starts.** **Measured:** 173 KB at 200 entities, 876 KB at 1,000. The function rejects bodies over 1,000,000 bytes, so somewhere above about 1,100 entities extraction silently loses its memory context.
3. **Server requests repeat the same checks one after another.** **Hops:** recall checks auth, then the notebook, then the rate limit before doing any work, though the rate-limit RPC already verifies auth and ownership. The AWS authorizer calls Supabase auth on every request with its cache turned off. Every Lambda request also reads the Gemini key from Secrets Manager.
4. **A new notebook can't hear you until the 3.45 s greeting has played** (**constant**). That's by design, so the mic doesn't catch Lumen's own voice, but it's the largest fixed wait in the app.
5. **The database is not the problem.** **Measured:** every call on the user's path runs in under 4 ms on a heavy user, except `get_user_graph` at 28 ms. The cost is round trips, payload size and model time.

## How long each moment takes

### 1. You stop talking → Lumen starts answering

This is the wait users feel most.

| Step | Time | Label |
|---|---|---|
| Gemini decides you've finished (`silence_duration_ms`) | 700 ms | constant |
| Mic audio is sent in chunks of about 100 ms | up to ~100 ms | constant |
| Gemini Live produces its first audio | 0.5–1.5 s | estimate: typical for native-audio Live models after end of turn |
| **With no tool call** | **≈ 1.3–2.3 s** | |
| + `get_graph_summary`: built on the phone | 13 ms (200 entities) to 231 ms (1,000), ×2–4 on an iPhone | measured |
| + `get_graph_summary`: Gemini reads the answer | 6k–31k extra input tokens per call; plausibly 0.2–1.5 s | estimate: grows with tokens |
| + `get_relevant_memory`: phone ↔ edge function round trip | 50–150 ms on LTE, 20–40 ms on Wi-Fi | estimate |
| + `get_relevant_memory`: inside the edge function | 5 sequential database hops plus one embedding (each in-region hop is 5–20 ms with PostgREST overhead), plus 41 ms ranking at 2,000 entities and a 508 KB graph download | hops + measured |
| + `get_relevant_memory`: cold start (first call after idle) | 0.5–2 s for the edge runtime and the `gte-small` model | estimate |
| **With recall, warm** | **≈ +0.3–0.8 s** | |
| **With recall, cold** | **up to the 3.5 s cap**, after which recall returns empty and Lumen answers without memory | constant |

The app answers any tool call after 4 s, empty if necessary (**constant**). Recall gives up at 3.5 s, leaving 0.5 s of headroom. Gemini can call `get_relevant_memory` up to 3 times per turn (`_maxMemoryCallsPerTurn`), and each call waits in sequence.

### 2. Opening a notebook

| Step | Time | Label |
|---|---|---|
| `get_notebook_snapshot` (phone → Supabase) | 1 round trip + 0.7 ms in the database, 13 KB | hops + measured |
| *then* the last 500 `conversation_turns` | 1 round trip + 0.1 ms in the database | hops + measured |
| Restoring the local turn journal | local disk | not measured |
| **Total** | **2 sequential phone round trips ≈ 100–300 ms on LTE** | estimate |

The two reads don't depend on each other. Running them in parallel saves one phone round trip.

### 3. Starting a new notebook → you can speak

| Step | Time | Label |
|---|---|---|
| Live token | about 0 when the token fetched at sign-in is still valid. Otherwise: authorizer auth call + Secrets Manager + Gemini token mint ≈ 0.3–0.8 s | constant (held token) / estimate |
| Socket open, then setup acknowledged | 2 sequential round trips to Gemini plus setup, ≈ 0.3–1 s | estimate |
| Greeting | starts as soon as the speaker and clip are ready, without waiting for the socket; plays for **3.45 s** | constant |
| **You can speak after** | **≈ 3.5–4 s** from opening. The greeting hides the connection time | |

### 4. A user turn → it appears on the graph

This doesn't delay Lumen's voice. It delays the upsert chip and the graph, and it holds up the next turn, because turns are extracted strictly in order.

| Step | Time | Label |
|---|---|---|
| Final transcript | 0 ms, or a 1,500 ms wait when Gemini sends `turnComplete` before the final transcript | constant |
| `retrieve-memory`, notebook scope | uploads the whole notebook: 42 KB / 173 KB / 876 KB at 50 / 200 / 1,000 entities. ≈ 0.2–0.7 s / 0.7–3.5 s on a 2–5 Mbps LTE uplink, plus 4 sequential hops and an embedding | measured + estimate |
| Extraction route: API Gateway + authorizer | 1 Supabase `/auth/v1/user` call per request (cache off) | hops |
| Extraction route: the Lambda | 5 sequential steps: notebook check → DynamoDB claim → Secrets Manager → Gemini → DynamoDB write | hops |
| Gemini `generateContent` (flash, thinking off) | 0.6–2 s | estimate |
| `commit_notebook` | 1 phone round trip + 0.9 ms in the database | hops + measured |
| **Total, warm, 200 entities** | **≈ 2–4.5 s**, most of it model time and upload | estimate |

### 5. Leaving a conversation → the card

| Step | Time | Label |
|---|---|---|
| Wait for pending turns, then `endNotebook` | depends on backlog; 1 round trip | hops |
| close-session Lambda | 7 sequential steps: notebook → stored card → snapshot ∥ turns → user entities → Secrets Manager → Gemini → save | hops |
| Gemini writes the card | 1–3 s | estimate |
| **Total, warm** | **≈ 1.5–4 s** while the card screen shows "Writing your card…". Returns immediately when the stored card is current | estimate |

## Findings, ranked by how much they cost a user

| # | Finding | Where | Fix | Expected saving |
|---|---|---|---|---|
| 1 | `get_graph_summary` sends every entity (6k–31k tokens per call) and has two quadratic loops: a relation scan per entity, and all entity pairs for bridges | `_buildGraphSummary` in `lib/providers/journal_provider.dart`, `buildAgenda` in `lib/logic/agenda.dart` | Send the top ~40 entities that matter (thin, just mentioned, with open questions) and index relations by entity once | Most of the token cost (about 1.5k tokens instead of 31k at 1,000 entities). CPU from ~231 ms to a few ms on this Mac |
| 2 | Extraction's retrieval uploads the whole notebook every turn, and breaks above about 1 MB | `_runDurableExtraction` calls `retrieveResult` in notebook scope | Use user scope (the server loads the graph), or send only the query and entity ids | 0.7–3.5 s per turn on LTE at 200–1,000 entities, and the 1 MB failure |
| 3 | Recall makes 3 checking hops before any work, and the embedding waits behind them | `supabase/functions/retrieve-memory/handler.ts` | One RPC that checks auth, ownership and the rate limit, and returns the user id. Start the embedding immediately | 2 hops plus the embedding overlap ≈ 50–150 ms per recall |
| 4 | Authorizer cache off, so every runtime request makes an extra auth call | `resultsCacheTtl: 0` in `infra/lib/infra-stack.ts` | Cache for 60–300 s keyed by token (tokens are short-lived), or verify the JWT locally with the project's signing key | 1 auth round trip (≈ 20–60 ms) per extraction and close |
| 5 | Gemini key read from Secrets Manager on every request | `index.mjs` in `extract-graph`, `close-session`, `live-session` | Keep it in module scope with a TTL (for example 5 minutes) | ≈ 10–40 ms per request |
| 6 | Opening a notebook reads the snapshot, then the turns | `_loadNotebookUnlocked` | `Future.wait` the two | 1 phone round trip ≈ 50–150 ms |
| 7 | close-session reads five things in sequence | `infra/lambda/close-session/core.mjs` | Read notebook ∥ stored card, then snapshot ∥ turns ∥ user entities | ≈ 3 hops (small); the model still dominates |
| 8 | Recall downloads the user's whole graph (508 KB at 2,000 entities) on every call | `get_user_graph(null, 2000)` in the recall path | Cache the graph per user for the session, or rank in SQL and return the top entities | 28 ms in the database plus transfer and parse, per recall |
| 9 | A turn without its final transcript waits 1.5 s before extraction | `finalizationDeadlineMs` | Keep it, it protects correctness; just track how often it fires (the timing log now shows it) | 0–1.5 s on affected turns |
| 10 | Turns are extracted strictly one after another | the turn effect queue | Keep the order for commits, but start the next turn's retrieval and model call while the previous one commits | Hides most of one turn's latency during fast back-and-forth |
| 11 | Ten timing constants in `conversation_policy.dart` are never used | `lib/logic/conversation_policy.dart` | Delete them, so nobody tunes a dead number | none (clarity) |
| 12 | Cold starts: the edge runtime with `gte-small`, and Lambdas at 256 MB on Node 22 | stack and edge config | Measure first with the probe (cold column). If they matter, raise Lambda memory (CPU scales with it) and keep a warm-up ping | Cold first calls only |

## Measured and fine

| What | 50 | 200 | 1,000 entities | Label |
|---|---|---|---|---|
| Extraction context compile | 1.0 ms | 0.3 ms | 0.9 ms | measured |
| Merging a patch | 0.05 ms | 0.07 ms | 0.24 ms | measured |
| Graph layout, one frame (50 / 150 / 300 nodes) | 0.7 ms | 0.5 ms | 1.7 ms | measured (budget 16.7 ms) |
| Markdown export (200 / 1,000) | | 7.5 ms | 22 ms | measured |
| Recall ranking in graphloop (200 / 1,000 / 2,000) | | 5.8 ms | 19 ms / 41 ms | measured |
| Database, heavy user (200 notebooks, 3,000 entity rows, 12,000 turns) | snapshot 0.7 ms, turns 0.1 ms, rate limit 0.1 ms, mentions 3.7 ms, embedding match 3.0 ms, commit 0.9 ms, `get_user_graph` 28 ms | | | measured |

## The tests

| File | What it measures | Run |
|---|---|---|
| `test/perf/latency_bench_test.dart` | App-side CPU and payload sizes at 50 / 200 / 1,000 entities | `flutter test test/perf --reporter expanded` |
| `test/perf/latency_budget_test.dart` | Pins every deliberate wait, and the rule that recall's cap stays under the tool timeout | same |
| `src/lib/graphloop/retrieve.perf.test.ts` | Recall ranking CPU at 200 / 1,000 / 2,000 entities | `npx vitest run src/lib/graphloop/retrieve.perf.test.ts` |
| `supabase/functions/retrieve-memory/handler.latency.test.ts` | Sequential hops in recall, both scopes | `deno test --allow-env supabase/functions/retrieve-memory/handler.latency.test.ts` |
| `infra/test/perf/server-hops.test.mjs` | Sequential hops in extraction and close-session | `cd infra && node --test test/perf/server-hops.test.mjs` |
| `supabase/tests/perf/rpc_timings.sql` | Database time for every call on the path, for a heavy user, rolled back afterwards | `docker exec -i supabase_db_bjoevzvsdlhlcjywpyfx psql -U postgres -d postgres -q < supabase/tests/perf/rpc_timings.sql` |
| `scripts/latency/probe-staging.mjs` | Real round trips, cold and warm, for each hop against staging | see its header (needs a staging test account) |
| `scripts/latency/voice-timing-report.mjs` | Real reply wait, tool times, connect and extraction from a device log | `node scripts/latency/voice-timing-report.mjs session.log` |

The perf tests in `test/perf/` run with the normal `flutter test` too. Their ceilings are loose, so they only fail on a real regression. The infra, Deno and SQL perf tests aren't in any default suite.

## To replace the estimates with real numbers

Two small changes in this branch make the device numbers collectable:

- `vlog` lines now carry a millisecond stamp (`[voice][client] @12345 …`).
- The live client logs `gemini → reply audio starts` on the first audio of every reply.

Both print in debug builds only. Then:

1. On an iPhone, start a debug build: `flutter run --debug 2>&1 | tee session.log`. Have a few minutes of Just talk that mentions earlier conversations, then leave.
2. Run `node scripts/latency/voice-timing-report.mjs session.log`. The `reply_wait` row is moment 1.
3. Run `scripts/latency/probe-staging.mjs` on the same network. Its cold column measures finding 12.

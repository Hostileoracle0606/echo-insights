# Memory Quality Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Plan 2 of 6 for the metrics showcase. Covers three of the seven test areas: continuity across sessions; memory correction and deletion; changing and tentative facts.

**Goal:** `npm run eval:memory` replays 12 scripted multi-session scenarios through Lumen's real extraction Lambda and commit path on a local Supabase stack, probes retrieval and the session-close brief, and writes scored counts per category.

**Architecture:** Two phases with a saved artifact between them. **Extract** (spends Gemini quota, resumable across days): per scenario, a fresh test user; each turn goes through `createExtractGraphHandler` in-process with the real Gemini key, the web app's `mergeExtraction`, and the `commit_notebook` RPC; scripted user actions (correct, remove, forget) call the same RPCs the app calls. The resulting graph is saved as a snapshot. **Probe** (free, rerunnable): restore each snapshot into a fresh user, run `embed-entities`, call `retrieve-memory` for every probe, call the brief handler once per scenario, and score. TypeScript app modules are loaded with `vite-node`, which honours the repo's Vite aliases.

**Tech Stack:** Node 20 ESM, `vite-node` (ships with vitest), `node:test` for pure modules, Supabase CLI local stack, Gemini free tier (`gemini-2.5-flash`).

**Spec:** `docs/superpowers/specs/2026-11-17-metrics-showcase-design.md`, Track 1.

## Global Constraints

- Local Supabase only: reuse `assertLocalTarget` from `eval/privacy/report.mjs`.
- Free tier: 20 requests/day/model. A run refuses to make more provider calls than `MEMORY_CALL_BUDGET` (default 18) and exits cleanly with the scenarios it finished; the next run resumes from saved snapshots.
- Extraction runs once per scenario (N=1). The report states this and claims no run-to-run spread.
- Scenario text is synthetic; no real journal content anywhere. Names in scenarios are invented.
- Metrics are counts over probes ("41/50"), never percentages alone.
- Results path: `eval/results/<YYYY-MM-DD>-<shortsha>/memory/` (`graphs/<scenario>.json`, `probes.json`, `memory.json`).
- Every test user is deleted at the end of a run; a sweep at start removes leftovers (`memory-eval-*@example.test`).
- The Groq edge function `supabase/functions/extract-graph` is never called.

## Review Focus

1. **Snapshot drift:** a restored snapshot must reproduce the committed graph exactly (entities, relations incl. `superseded_at`, suppressions, entries). Round-trip test in Task 3.
2. **Vacuous probes:** a probe whose expected entity was never extracted scores as an extraction miss, not a retrieval miss. `score` separates `not_extracted` from `not_retrieved` (Task 5).
3. **Quota exhaustion mid-scenario:** a 429 or budget stop leaves no half-saved snapshot; the scenario restarts from its first session next run (Task 4).
4. **Forgotten names in the brief:** after a `forget` step, the brief and retrieval must not contain the name; scored as stale resurfacing (Task 5).
5. **Path attribution:** if `retrieve-memory` doesn't label which path (lexical, semantic, graph) returned an item, report `combined` and say so; never guess (Task 4).

---

### Task 1: Scenario format and corpus

**Files:**
- Create: `eval/memory/scenario.mjs`, `eval/memory/scenario.test.mjs`, `eval/memory/scenarios/*.json` (12 files)

**Interfaces:**
- Produces: `loadScenarios(dir: string): Scenario[]` (throws naming file and field on any schema error); `CATEGORIES = ['continuity','correction','deletion','changing_facts']`.
- Scenario shape (JSON, not YAML; no new dependency):
  ```json
  {"id":"job-change-decided","category":"changing_facts",
   "sessions":[{"turns":["I might leave Northwind, the commute is killing me."]},
               {"turns":["Talked it over with Priya. I decided to stay at Northwind."]}],
   "actions":[{"after_session":1,"kind":"forget","name":"Priyanka"}],
   "probes":[{"ask":"What happened with the job thing?","expect_retrieved":["Northwind"],
              "expect_not_retrieved":["Priyanka"],"expect_status":"decided",
              "decided_markers":["stay"],"tentative_markers":["might leave"],
              "expect_ambiguity":false}]}
  ```
  `actions[].kind` ∈ `correct` (`{name, description}` via the app's edit-description path), `remove` (`remove_entity`), `forget` (`forget_entity`).

- [ ] **Step 1: Write failing tests:** a valid file loads; missing `probes`, an unknown `category`, an action `after_session` past the last session, and an empty `expect_retrieved` with no `expect_not_retrieved` each throw with the file name in the message; the shipped corpus loads with exactly 12 scenarios split 4/3/2/3 across the categories, and ≥45 probes total.
- [ ] **Step 2: Run** `node --test eval/memory/scenario.test.mjs` → FAIL.
- [ ] **Step 3: Implement** `scenario.mjs` and write the corpus: continuity (indirect reference, paraphrase, two ambiguous-name cases such as two people called Sam); correction (wrong job title fixed next session; wrong city fixed in the same session; correction via edit description); deletion (remove a project; forget a person); changing facts (tentative → decided; decided → reversed; similar-name distractor). Average ≤2.5 sessions and ≤1.5 turns per session (budget ≈30 extraction calls).
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** `feat(eval): memory scenario format and corpus`

### Task 2: Quota budget and resumable progress

**Files:**
- Create: `eval/memory/budget.mjs`, `eval/memory/budget.test.mjs`

**Interfaces:**
- Produces: `createBudget(limit: number): {take(): boolean, used(): number}`; `providerFetch({realFetch, budget, providerHosts}): fetchImpl` — passes Supabase-origin requests through; for provider hosts calls `budget.take()` and throws `BudgetExhausted` when false; maps a provider 429 to `QuotaExhausted`.

- [ ] **Step 1: Failing tests:** `take()` returns true `limit` times then false; `providerFetch` never calls `realFetch` for a provider host once the budget is spent; a 429 from the provider throws `QuotaExhausted`; Supabase-origin calls never consume budget.
- [ ] **Step 2–4:** run → FAIL, implement, run → PASS. **Step 5: Commit** `feat(eval): provider call budget for free-tier runs`

### Task 3: Graph snapshot and restore

**Files:**
- Create: `eval/memory/snapshot.mjs`, `eval/memory/snapshot.test.mjs`

**Interfaces:**
- Consumes: `rowFor`/`SEED_ORDER` conventions from `eval/privacy/fixtures.mjs` (table order only).
- Produces: `SNAPSHOT_TABLES` (notebooks, journal_entries, entities, relations, entity_suppressions, conversation_turns); `takeSnapshot({url, adminHeaders, userId}) => Snapshot` (ids rewritten to stable placeholders, user id removed); `restoreSnapshot({url, adminHeaders, userId, snapshot}) => {notebookId}`; `snapshotDigest(snapshot) => string` (sha256 of canonical JSON, ignoring placeholders).

- [ ] **Step 1: Failing unit test** for id rewriting and `snapshotDigest` stability (same graph, different uuids → same digest). **Integration test** (skipped unless `SUPABASE_URL` is local): seed a graph, take, restore into a second user, take again → equal digests, `superseded_at` preserved.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): memory graph snapshot and restore`

### Task 4: Extract phase and probe phase

**Files:**
- Create: `eval/memory/replay.ts`, `eval/memory/probe.mjs`, `eval/memory/run.ts`
- Modify: `package.json` (`"eval:memory": "vite-node eval/memory/run.ts"`)

**Interfaces:**
- Consumes: `createExtractGraphHandler` (`infra/lambda/extract-graph/core.mjs`), `createSessionBriefHandler` (`infra/lambda/close-session/brief.mjs`), `mergeExtraction` (`src/lib/journal-store.ts`), `memoryClaimStore` and `gatewayInvoke` (`eval/privacy/probes/lambdas.mjs`), Tasks 1–3.
- Produces: `replayScenario({scenario, env, fetchImpl}) => Snapshot` (throws `BudgetExhausted`/`QuotaExhausted` without saving); `probeScenario({snapshot, scenario, env}) => ProbeResult[]` where `ProbeResult = {scenario, probeIndex, retrieved: [{name, text, path}], brief: {text}|null, extracted: string[]}`.

Rules: the extraction request body is built exactly as `src/lib/extract-graph.ts` builds it for the gateway (read it; don't re-derive). Turns commit with the same `p_change` shape `src/lib/notebook-commit.ts` sends. The brief handler gets the real Gemini text call; its TTS call is answered by a stub (TTS quota is separate and audio isn't scored). Retrieval runs at `scope:notebook`, `k=8`. `embed-entities` runs before probing, via `EMBED_INTERNAL_SECRET`.

- [ ] **Step 1: Failing test** (`node --test`, stubbed fetch): `replayScenario` on a 2-session scenario calls the extractor once per turn, commits once per turn with increasing `p_expected_revision`, applies the `forget` action after session 1, and throws `BudgetExhausted` without writing a snapshot when the budget runs out mid-scenario.
- [ ] **Step 2–4.**
- [ ] **Step 5: Run for real:** local stack up, functions served, `GEMINI_API_KEY` set, `npm run eval:memory -- --phase extract`. Expected: snapshots for as many scenarios as the budget allows; exit 0 with `resume tomorrow: N scenarios left` if quota ran out. Commit snapshots.
- [ ] **Step 6: Commit** `feat(eval): memory replay and probe runner`

### Task 5: Scorer and report

**Files:**
- Create: `eval/memory/score.mjs`, `eval/memory/score.test.mjs`, `eval/memory/README.md`

**Interfaces:**
- Produces: `scoreProbe(probe, result) => {recall: [hit, of], precision: [hit, of], inserted: number, stale: boolean, status: 'correct'|'wrong'|'n/a', order: 'kept'|'lost'|'n/a', ambiguity: 'acknowledged'|'missed'|'n/a', misses: [{name, why: 'not_extracted'|'not_retrieved'}]}`; `summarize(scored) => memory.json` with per-category counts for: recall@8, precision@8, unrelated-insertion count, stale resurfacing (split by `path` and `brief`), tentative/decided accuracy, sequence preservation, ambiguity acknowledged.

Status rule: `decided` is correct when a non-superseded relation or entity description retrieved for the probe contains a `decided_marker` and none contains a `tentative_marker`. Lumen has no tentative/decided field, so this measures what the stored text says; the README states that.

- [ ] **Step 1: Failing tests** for each metric with hand-built results, including: a stale name only in the brief counts as stale (`brief`); an expected entity absent from `extracted` is `not_extracted`, not a recall miss against retrieval.
- [ ] **Step 2–4.**
- [ ] **Step 5: Run** `npm run eval:memory -- --phase probe` → `memory.json`. Record failures as findings; do not edit scenarios to pass.
- [ ] **Step 6: Commit** `feat(eval): memory scorer and first results`

**Deferred (not in this plan):** spoken-answer transcripts scored by an LLM judge (5-scenario subset) — needs Live quota scheduling; a later plan.

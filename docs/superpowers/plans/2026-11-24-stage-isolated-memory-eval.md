# Stage-Isolated Memory Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `npm run eval:stages` measures Lumen's memory pipeline stage by stage (extraction, admission, oracle retrieval, end to end) on a ~500-query synthetic held-out benchmark plus small public slices, with history-level bootstrap CIs and a baseline report attributing failures to stages.

**Architecture:** New `eval/stages/` beside the existing `eval/memory/` harness (Node, `vite-node`), reusing its in-process Lambdas, replay, snapshot restore, background distractors, local stack and judge pieces. Ground truth is generated in code (seeded worlds); Claude writes only language, through Claude Code headless on the owner's plan. Datasets are JSONL with zod schemas.

**Tech Stack:** Node 20 ESM, TypeScript via `vite-node`, `node:test`, `zod` (already a dependency), Supabase CLI local stack, Gemini `gemini-2.5-flash` (system under test), Claude Code CLI (`claude -p`) on the owner's plan.

**Spec:** `docs/superpowers/specs/2026-11-24-stage-isolated-memory-eval-design.md`

## Global Constraints

- No production change: nothing outside `eval/`, `package.json` scripts and docs is edited. `eval/memory/replay.ts` may gain optional hooks; its current behaviour and tests stay unchanged.
- Local Supabase only (`assertLocalTarget`).
- **Claude never through the API.** Every Claude call goes through `eval/lib/claude-plan.mjs`: `claude -p --model opus --no-session-persistence --tools "" --setting-sources "" --strict-mcp-config --mcp-config <file with {"mcpServers":{}}> --disable-slash-commands --no-chrome --system-prompt <rubric> --output-format json --json-schema <schema>`, run in an empty temp dir with `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` removed from the env. A plan usage-limit message stops the run cleanly (`PlanLimitReached`); the run resumes from cache.
- Gemini spend cap: $15 for the first full baseline, tracked in `eval/results/stages-spend-log.json`, enforced before each call.
- Every dataset and result file carries `synthetic: true` or `source: <public set>`; no real user data anywhere.
- The embedded entity text is produced only by running `supabase/functions/embed-entities` (today `name + "\n" + description`); nothing re-derives it.
- No result is hand-edited. A failed generation is regenerated, never patched.
- Results: `eval/results/<YYYY-MM-DD>-<sha>/stages/`. Datasets: `eval/stages/data/{train,val,test}/`.

## Review Focus

1. **Leakage through names or templates:** a test world reusing a train name, or a test question generated from a train phrasing instruction. Task 4's gate must fail the build on either.
2. **Future-fact leakage inside a history:** a session-2 turn that already states a session-4 change makes temporal queries trivial. Task 3 validation rejects it.
3. **Vacuous oracle results:** a gold graph whose entities never got embeddings would make "hybrid" silently lexical. Task 8 asserts every non-background entity has an embedding row with the current model before querying.
4. **Plan auth falling back to the API:** a run with `ANTHROPIC_API_KEY` still visible would bill API credit. Task 1 tests the child env never contains it and refuses to run if `claude auth status` doesn't report `claude.ai`.
5. **Correlated queries in CIs:** resampling queries instead of histories gives falsely narrow intervals. Task 6 tests that resampling moves whole histories.

---

### Task 1: Claude-on-plan client, and move the memory judge onto it

**Files:**
- Create: `eval/lib/claude-plan.mjs`, `eval/lib/claude-plan.test.mjs`
- Modify: `eval/memory/judge.mjs` (`ask` takes a runner instead of an SDK client), `eval/memory/judge.test.mjs`, `eval/memory/run.ts` (judge uses `createPlanRunner`), `package.json` (remove `@anthropic-ai/sdk`)

**Interfaces:**
- Produces: `createPlanRunner({ spawnImpl = child_process.spawn, model = 'opus', cwdFactory, authCheck }) => { run({ system, prompt, schema }) => Promise<{ output: object, usage: object, costNotional: number }> }`; `PlanLimitReached`, `PlanUnavailable` errors; `assertPlanAuth(spawnImpl)` (runs `claude auth status`, requires `authMethod === 'claude.ai'`).
- `judge.mjs`: `ask(runner, text, schema)` returns `{ verdict, model: 'claude-opus (plan)', usage }`; `JUDGE_MODEL = 'opus via Claude Code (plan)'`; cache keys change accordingly (RUBRIC_VERSION stays 2).

- [ ] **Step 1: Failing tests** with a fake `spawnImpl`: the child env has no `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` even when the parent has them; argv contains every flag in Global Constraints and `--json-schema` equal to `JSON.stringify(schema)`; `structured_output` is returned; `is_error: true` with a usage-limit message throws `PlanLimitReached`; other errors throw `PlanUnavailable`; `assertPlanAuth` rejects `authMethod: 'console'`.
- [ ] **Step 2:** `node --test eval/lib/claude-plan.test.mjs` → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5:** switch `judge.mjs`/`run.ts` to the runner; update `judge.test.mjs` fakes to the runner shape; `node --test eval/memory/*.test.mjs` → all pass.
- [ ] **Step 6: Live check:** `npm run eval:memory -- --phase judge` re-judges with calibration 8/8 on the plan (cache misses are expected; no API key in env). Commit `feat(eval): Claude calls run on the plan via Claude Code headless`.

### Task 2: World generator and schemas

**Files:**
- Create: `eval/stages/gen/schema.mjs`, `eval/stages/gen/world.mjs`, `eval/stages/gen/names.mjs`, `eval/stages/gen/world.test.mjs`

**Interfaces:**
- Produces: `FAMILIES = ['temporal_change','ambiguity','multi_hop','contradiction','paraphrase','distractor','unanswerable']`; zod `WorldSchema`, `QuerySchema`; `makeWorld({ seed, split, families }) => World` where `World = { id, split, synthetic: true, seed, families, entities: [{ id, name, aliases, type, attributes }], sessions: [{ facts: Fact[], actions: Action[] }], finalGraph: { entities, relations: [{ source, label, target, supersededInSession? }] }, queries: [{ id, family, template, gold: [{ entityId, relevance: 1|2 }], answer, answerable }] }`; `namePool(split)` returns a pool disjoint from the other splits.

- [ ] **Step 1: Failing tests:** same seed → deep-equal world; different seeds differ; every world validates; each family in a world contributes ≥1 query whose gold is non-empty except `unanswerable` (gold empty, `answerable: false`); a `temporal_change` world's finalGraph has a superseded relation; `ambiguity` worlds have two entities sharing a first name; `multi_hop` queries have one relevance-2 and ≥1 relevance-1 entity; name pools of train/val/test are pairwise disjoint.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): seeded world generator with gold labels`

### Task 3: Language writing and validation (Claude on the plan)

**Files:**
- Create: `eval/stages/gen/write.mjs`, `eval/stages/gen/prompts.mjs`, `eval/stages/gen/write.test.mjs`

**Interfaces:**
- Consumes: `createPlanRunner` (Task 1), `World` (Task 2).
- Produces: `writeWorld({ world, runner, phrasingSet }) => { turns: [{ session, text, requiredFacts }], queries: [{ id, text }] }`; `validateTurns(world, turns) => string[]` (errors); `PHRASING_SETS = { train: [...], val: [...], test: [...] }` (disjoint instruction sets for question wording).

Validation: each turn mentions every name its facts require (name or alias, normalized); no turn mentions a fact first introduced in a later session; each query mentions no gold entity's attribute value verbatim when the family is `paraphrase`; unanswerable queries name no entity in the world. Up to 2 regenerations; then the world is dropped and logged.

- [ ] **Step 1: Failing tests** with a fake runner: a turn missing a required name fails validation; a session-1 turn stating a session-3 fact fails; a valid set passes; after 2 bad generations the world is dropped (not patched); outputs are cached by hash so a rerun makes zero runner calls.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): Claude-written turns and questions with validation`

### Task 4: Build CLI — splits, dedup, leakage gate, manifest

**Files:**
- Create: `eval/stages/gen/build.ts`, `eval/stages/gen/leakage.mjs`, `eval/stages/gen/leakage.test.mjs`
- Modify: `package.json` (`"eval:stages:gen": "vite-node --config eval/memory/vite.config.ts eval/stages/gen/build.ts"`)

**Interfaces:**
- Produces: `normalize(text)`, `jaccard(a, b)`, `shared8gram(a, b)`, `leakageReport(testItems, otherItems) => [{ testId, otherId, reason }]`; CLI `--split train|val|test --worlds N --seed S [--smoke]` writing `eval/stages/data/<split>/{worlds.jsonl,queries.jsonl,manifest.json}`; manifest `{ synthetic: true, generatorCommit, seeds, counts, droppedWorlds, leakage: 'clean' }`.

- [ ] **Step 1: Failing tests:** Jaccard ≥ 0.8 is flagged; a shared 8-gram is flagged; within-split duplicates are removed; the build exits non-zero when `leakageReport` is non-empty.
- [ ] **Step 2–4.**
- [ ] **Step 5:** `npm run eval:stages:gen -- --split test --worlds 3 --smoke` → 3 worlds, manifest clean. Commit `feat(eval): benchmark build with splits and leakage gate`.

### Task 5: Review sample and review page

**Files:**
- Create: `eval/stages/gen/review.mjs`, `eval/stages/gen/review.test.mjs`, `eval/stages/gen/review-page.html` (static page reading a JSON sample, recording verdicts to a downloadable JSON pasted back by the owner)

**Interfaces:**
- Produces: `reviewSample(queries, { perFamily: 10, seed }) => Item[]`; `recordReview(sample, verdicts) => { perFamily: { ok, wrong, of }, wrongIds }` written to the test manifest.

- [ ] **Step 1: Failing tests:** sample has ≤10 per family and is deterministic per seed; `recordReview` rejects verdicts for ids not in the sample.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): stratified review sample and page`

### Task 6: Metrics and history-level bootstrap

**Files:**
- Create: `eval/stages/metrics.mjs`, `eval/stages/stats.mjs`, `eval/stages/metrics.test.mjs`, `eval/stages/stats.test.mjs`

**Interfaces:**
- Produces: `prf(tp, fp, fn)`, `recallAt(ranked, gold, k)`, `mrr(ranked, gold)`, `ndcgAt(ranked, gradedGold, k)`, `percentile(values, p)` (nearest-rank); `bootstrap({ items, groupKey, metric, resamples = 2000, seed }) => { value, lo, hi }`; `pairedBootstrap({ items, groupKey, a, b, ... }) => { diff, lo, hi }`.

- [ ] **Step 1: Failing tests:** hand-computed NDCG@10 with graded gold (2 at rank 2, 1 at rank 5) equals the closed form; MRR for first hit at rank 3 is 1/3; bootstrap with a fixed seed is deterministic; a resample always contains whole groups (assert via a metric that counts distinct groups per resample); paired bootstrap of identical a and b gives diff 0 with lo = hi = 0.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): ranking metrics and history-level bootstrap`

### Task 7: Replay tracks — extraction and admission

**Files:**
- Create: `eval/stages/tracks/replay.ts`, `eval/stages/tracks/match.mjs`, `eval/stages/tracks/match.test.mjs`
- Modify: `eval/memory/replay.ts` (optional `onTurn({ turnId, patch, commitOutcome, snapshot })` hook; default no-op)

**Interfaces:**
- Consumes: `replayScenario` (+ hook), `takeSnapshot`, `createPlanRunner`, metrics.
- Produces: `worldToScenario(world, turns)` (memory-harness scenario shape); `matchEntities(predicted, goldEntities) => { tp, fp, fn, map }` (normalized name + aliases); `pairF1`, `typedF1(runner)` (label equivalence judged by Claude, cached); `admissionOutcome(validItem, beforeSnapshot, afterSnapshot, commitOutcome) => 'persisted'|'rejected'|'merged_correct'|'merged_wrong'`; per-world JSONL rows for both tracks.

- [ ] **Step 1: Failing tests:** alias match counts as TP; a whole-turn `invalidChange` marks every valid item of that turn `rejected`; an item that lands on an existing gold-matching entity is `merged_correct`, on a different gold entity `merged_wrong`; existing `eval/memory` replay tests still pass with the hook absent.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): extraction and admission tracks`

### Task 8: Oracle retrieval track

**Files:**
- Create: `eval/stages/tracks/oracle.mjs`, `eval/stages/tracks/oracle.test.mjs`

**Interfaces:**
- Consumes: `restoreSnapshot`, `backgroundRows`, `embedNotebook`, metrics.
- Produces: `goldSnapshot(world) => Snapshot` (one fixed description template per entity; superseded relations carry `superseded_at`); `runOracle({ world, queries, stack, mode: 'hybrid'|'lexical', k: 10 })` → rows `{ worldId, queryId, family, ranked, metrics }`. `lexical` = the same notebook with no embedding rows (production's own fallback path), `hybrid` = after `embedNotebook` confirms zero stale rows.

- [ ] **Step 1: Failing tests:** `goldSnapshot` validates against `snapshotDigest` round trip; superseded relations keep `superseded_at`; hybrid refuses to query when any non-background entity lacks an embedding row for the current model (Review Focus 3); unanswerable queries are excluded from rank metrics.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): oracle retrieval track (hybrid and lexical)`

### Task 9: End-to-end track, attribution, latency

**Files:**
- Create: `eval/stages/tracks/e2e.ts`, `eval/stages/tracks/attribution.mjs`, `eval/stages/tracks/answer-prompt.mjs`, `eval/stages/tracks/attribution.test.mjs`, `eval/stages/tracks/answer-prompt.test.mjs`

**Interfaces:**
- Produces: `productionAnswerPrompt()` (reads the prompt from `lib/logic/conversation_policy.dart`; falls back to a frozen copy guarded by a hash test); `answer({ query, context, geminiKey, fetchImpl })` (one Gemini text call, counted against the spend cap); `judgeAnswer(runner, { query, gold, answer, answerable })` → `correct|wrong|abstained` with reason; `attribute({ goldIds, extracted, persisted, rankedTop10, verdict, answerable }) => 'extraction'|'admission'|'retrieval'|'answer'|null`; latency rows per stage.

- [ ] **Step 1: Failing tests:** attribution picks the first losing stage in pipeline order; unanswerable answered → `answer`; correct → `null`; the frozen-prompt hash test fails when the Dart source's prompt text changes.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): end-to-end track with stage attribution and latency`

### Task 10: CLI, smoke test, report

**Files:**
- Create: `eval/stages/run.ts`, `eval/stages/report.mjs`, `eval/stages/report.test.mjs`, `eval/stages/README.md`
- Modify: `package.json` (`"eval:stages": "vite-node --config eval/memory/vite.config.ts eval/stages/run.ts"`)

**Interfaces:**
- Produces: CLI `--track extraction|admission|oracle|e2e|all --split test|val [--only <world>] [--smoke]`; `summary.json` (every metric with `{ value, lo, hi, n, histories }`, attribution shares with CIs, spend, plan calls, `synthetic: true`); `baseline-report.md` naming the stages with the largest failure share; legacy `eval:memory` summary linked.

- [ ] **Step 1: Failing test:** `report.mjs` renders shares that sum to 100% of e2e misses and never prints a metric without its CI and N.
- [ ] **Step 2–4.**
- [ ] **Step 5: Smoke run:** `npm run eval:stages:gen -- --split test --worlds 3 --smoke` then `npm run eval:stages -- --track all --split test --smoke`. Expected: every track writes rows for 3 worlds, Gemini spend < $0.50, plan calls reported, no API key used. Record anything broken as a ruling; don't scale up until the smoke run is clean.
- [ ] **Step 6: Commit** `feat(eval): stages CLI, smoke run and report`

### Task 11: Full benchmark and baseline

- [ ] **Step 1:** generate train (~300 worlds), val (~40), test (~100); leakage gate clean.
- [ ] **Step 2:** owner reviews the 60-item sample (Task 5); regenerate items marked wrong; record per-family error rates.
- [ ] **Step 3:** `npm run eval:stages -- --track all --split test` (resumable within caps) plus `npm run eval:memory -- --phase all` (legacy).
- [ ] **Step 4:** commit datasets, results and `baseline-report.md`: `test(eval): stage-isolated baseline on 500 synthetic held-out queries`.

### Task 12: Public slices (each gated on owner approval of its download)

**Files:**
- Create: `eval/stages/public/{dialogre,perltqa,longmemeval}.mjs` with fixture tests, `eval/stages/public/README.md` (source, licence, slice, mapping)

- [ ] **Step 1:** for each set, ask the owner with name, source URL, size and licence; download only on a yes into `eval/stages/public/data/` (git-ignored).
- [ ] **Step 2:** converters to Lumen's world/query shape, tested on a 2-item hand fixture each.
- [ ] **Step 3:** run DialogRE through extraction (~100 dialogues), PerLTQA through oracle retrieval (~200 questions), LongMemEval slice end to end (~30 questions); report separately with `source:` labels. Commit `test(eval): public-set checks`.

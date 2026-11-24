# Stage-isolated memory evaluation — design

Date: 2026-11-24 · Status: draft for approval
Branch: builds on `claude/eval-memory-7cf6d4` (the memory harness in `eval/memory/`).

## Intent

Lumen's memory pipeline is extraction → admission (merge + `commit_notebook`)
→ retrieval (`retrieve-memory`: lexical + gte-small semantic seeds + graph
expansion) → the answer the voice model gives. The 48-probe memory eval showed
most misses happen *before* retrieval, but it can't say how much, with what
uncertainty, or whether retrieval itself is good. This phase measures each
stage on its own and end to end, on a benchmark large enough to give
confidence intervals, and produces a baseline report naming the stages that
cause most failures. It is also the yardstick for the later trainable-embedding
work.

## Goals

1. Four tracks, each runnable alone: **extraction**, **admission**, **oracle retrieval**, **end-to-end recall**.
2. A synthetic benchmark: ~500 held-out **test** queries over diverse conversation histories, plus **train** and **validation** splits for later model work.
3. One public dataset per track as an outside check (owner decision): DialogRE (extraction), PerLTQA (oracle retrieval), a LongMemEval slice (end to end).
4. The 48 legacy probes kept unchanged as a regression suite.
5. Metrics with paired, history-level bootstrap 95% CIs; machine-readable results; a baseline report with failure attribution by stage.

## Non-goals

- Changing production retrieval, extraction, admission or prompts. This phase only measures.
- Training or swapping embedding models (next phase).
- Voice/Live audio. End-to-end answers are text.

## Anti-goals (failure even if it runs)

- Any fabricated or hand-edited result; any real user data.
- Train/test leakage: a test history, entity name, question, or near-paraphrase also present in train/val.
- Measuring a reimplementation instead of production code (re-deriving the embedder text, merge rules, or retrieval).
- Unlabelled synthetic data: every dataset file and report says `synthetic` or names its public source.

## Constraints

- Local Supabase only; the production embedder, `entity_embeddings` model versioning and pgvector stay as they are.
- The embedded entity text is whatever `supabase/functions/embed-entities` embeds (today `name + "\n" + description`); the oracle track gets it by running that function, never by copying the format.
- Gemini (paid key) is the system under test; Claude generates data and judges. Claude never grades text Claude wrote as a stand-in for Lumen.
- **No Claude API spend.** Everything Claude does (writing turns and questions, judging) runs through Claude Code in headless mode (`claude -p --json-schema …`) on the owner's Claude plan, with `ANTHROPIC_API_KEY` removed from its environment so it can never fall back to paid credit. A call that would bill the API is a bug. The plan's usage limits pace the run: it stops cleanly when the plan says to wait, and resumes.
- Gemini spend cap, enforced in code: ≤ $15 for the first full baseline.
- Downloads of public datasets need the owner's go-ahead per dataset (name, source, size, licence) before fetching.

## Approaches considered

- **A. Extend the Node memory harness (chosen).** Reuses in-process Lambdas, the app's merge path, `retrieve-memory` on local Supabase, snapshot restore, and the Claude judge. Data as JSONL with schemas, readable by later PyTorch work.
- **B. Same, with Python analysis.** Standard ML tooling, but two toolchains and a project Python env; its main benefit (training-ready data) comes free with A's JSONL.
- **C. Python framework over HTTP.** Can't run the Lambdas in-process; would re-implement merge logic and widen the gap between test and production.

## Design

### Benchmark generation (`eval/stages/gen/`)

Ground truth comes from code; Claude only writes language.

1. **World** (seeded PRNG, deterministic): a user, 4–10 entities (people, places, orgs, projects, events) drawn from a name pool, typed attributes, relations, and a timeline of 3–6 sessions in which facts are introduced, changed, corrected, contradicted, or removed (`remove_entity` / `forget_entity` actions as the app performs them).
2. **Scenario families** (each world mixes 2–3): temporal change, entity ambiguity (shared first names, similar names), multi-hop relations, contradiction/correction, paraphrased reference, semantically similar distractors, unanswerable (asks about something never said or since forgotten).
3. **Gold labels from the world**, per turn: entities, attributes, relations that turn states; per session end: the expected graph (current facts; superseded facts marked); per query: gold entity ids with graded relevance (2 = answers it, 1 = needed hop), gold answer, `answerable`.
4. **Claude writes** the user's turns for each session from the facts that turn must state, and the query wording. Each output is schema-validated (zod), checked that every required name/fact appears in the turn it belongs to and no fact from a later session leaks early, and rejected/regenerated otherwise (max 2 retries; failures logged, never patched by hand).
5. **Splits by world**, never by query: train / val / test from disjoint name pools (entity universe), disjoint world seeds (history), and for test, question wording from a held-out set of phrasing instructions (generation scenario). Leakage gate: normalized token-Jaccard ≥ 0.8 or shared 8-gram between any test query/turn and any train/val one fails the build.
6. **Sizes:** test ~100 worlds × ~5 queries ≈ 500; val ~40 worlds ≈ 200; train ~300 worlds ≈ 1,500 (train needs no pipeline runs, only generation). Dedup within splits on the same measure.
7. **Manual review:** the owner reviews a stratified sample of ~60 test items (10 per scenario family) on a local review page: turn ↔ label agreement, query ↔ gold agreement. Error rate per family is reported with the benchmark; items marked wrong are fixed by regeneration, never edited.

### Tracks (`eval/stages/tracks/`)

- **Extraction:** replay each test history turn-by-turn through the production path the memory harness already uses (extraction Lambda in-process, real Gemini). Match predicted to gold entities by normalized name + aliases. Report entity P/R/F1, attribute recall, and relation F1 two ways: **pair F1** (source, target; deterministic) and **typed F1** where label equivalence ("works_at" ≈ "employed_by") is judged by Claude and cached.
- **Admission:** for each turn, compare the extraction patch with what `commit_notebook` actually persisted (snapshot diff). Per valid extracted item (matches gold): persisted / rejected (whole-turn `invalidChange` or other) / merged (correctly into the gold entity, or wrongly into another). Metrics: valid-memory persistence rate, false rejection rate, wrong-merge rate.
- **Oracle retrieval:** build each history's gold end-state graph directly (snapshot restore; no extraction or admission), add the 50 background distractors, run `embed-entities`, query `retrieve-memory` (notebook scope). Metrics on the ranked entity list: Recall@1/5/10, MRR, NDCG@10 (graded gold). Run for both current modes: hybrid (production) and lexical-only (the fallback), as a paired comparison.
- **End-to-end:** run the whole pipeline on the test history, then generate a text answer with Gemini from `retrieve-memory`'s context and the production conversation prompt (`lib/logic/conversation_policy.dart` wording, loaded from source). Claude judges correct / wrong / abstained against the gold answer; unanswerable queries are correct only when abstained. Calibration cases as in the memory judge.
- **Latency:** P50/P95 per stage (extraction, commit, embed, retrieval, answer), labelled *local stack*.
- **Failure attribution:** for each end-to-end miss, the first stage where the gold entity is lost: not extracted → extraction; extracted but not persisted or wrongly merged → admission; persisted but not in top 10 → retrieval; retrieved but answer wrong → answer. Unanswerable answered → answer (hallucination).

### Shared run mechanics (settled in the builder check)

- **One replay feeds three tracks.** Each test history is replayed once; that replay's per-turn patches, commit outcomes and snapshots feed extraction, admission and end-to-end. Histories contain user turns only, as in the memory harness.
- **Queries are asked at the end of the history**, against the final graph. Temporal queries ("where did Imogen live before?") rely on superseded relations being kept, as production does.
- **Gold-to-retrieved matching:** in oracle runs the harness creates the entity ids, so matching is by id; in end-to-end runs retrieved entities are matched to gold by normalized name and aliases.
- **Oracle descriptions** are written deterministically from world facts with one fixed sentence template. Their style differs from extractor-written descriptions; the report states this.
- **Attributes** are scored as recall of each gold attribute value in the extracted description or relations (normalized match).
- **Unanswerable queries** are excluded from rank metrics and scored only end to end (abstention).
- **Answer prompt:** the end-to-end answer uses the production prompt text read from `lib/logic/conversation_policy.dart` at run time; if it can't be extracted, a frozen copy is used with a test that fails when the source changes.
- **Models:** Claude Opus through Claude Code headless on the owner's plan (`--model opus`) for generation and judging; the existing memory judge (`eval/memory/judge.mjs`) moves to the same backend, its API path removed; Gemini `gemini-2.5-flash` via the production Lambdas for extraction, and the same model for text answers.

### Public checks (`eval/stages/public/`)

Small fixed slices, mapped to Lumen's format by a documented converter, each run only after the owner approves its download and licence: DialogRE dev/test dialogues (relation F1), PerLTQA memories + questions (oracle retrieval), LongMemEval knowledge-update and abstention questions with the shortest histories (end to end). Reported separately from the synthetic results, never merged. Slice sizes: about 100 DialogRE dialogues, 200 PerLTQA questions, and 30 LongMemEval questions, kept small to stay inside the spend caps.

### Statistics and outputs

- Paired bootstrap, 2,000 resamples, resampling **histories** (queries within a history move together); 95% percentile CIs for every metric and for paired differences (e.g. oracle − end-to-end recall, hybrid − lexical).
- CLI: `npm run eval:stages -- --track extraction|admission|oracle|e2e|all --split test|val [--only <world>]`, resumable, with cost caps.
- Outputs under `eval/results/<date>-<sha>/stages/`: per-item JSONL per track, `summary.json` (metrics + CIs + attribution), `baseline-report.md`. Dataset files under `eval/stages/data/{train,val,test}/` with a manifest (generator commit, seed, counts, review results, `synthetic: true`).
- Legacy suite: `npm run eval:memory` unchanged; its 48 probes are reported alongside.

## Left to the builder

Exact scenario-family templates and name pools, the review page's look, converter details for each public set, judge rubric wording (with calibration cases), and file layout inside `eval/stages/`.

## My calls (owner can override)

- Manual review is done by the owner, because Claude reviewing Claude-generated labels isn't independent.
- Gemini cap above; Claude work runs on the plan, not the API; the first full baseline runs test + legacy; val is generated but only run for spot checks.
- Train split is generated now but not used in this phase.

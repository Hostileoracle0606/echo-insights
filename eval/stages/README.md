# Stage-isolated memory evaluation

Measures each stage of Lumen's memory pipeline on its own and end to end, on a
**synthetic** held-out benchmark: extraction → admission (merge +
`commit_notebook`) → retrieval (`retrieve-memory`) → the answer. Design:
`docs/superpowers/specs/2026-11-24-stage-isolated-memory-eval-design.md`.
Nothing here changes production behaviour.

## Data (`gen/`)

- **Ground truth in code** (`world.mjs`): seeded worlds of 3–5 sessions with people, places, organisations, projects and events; what changes when (moves, corrections, removals); and each question's gold entities (relevance 2 = answers it, 1 = needed hop), answer and answerability. Seven families: temporal change, ambiguity (shared first names), multi-hop, contradiction/correction, paraphrase, similar-name distractors, unanswerable.
- **Language by Claude** (`write.mjs`), on the owner's plan through Claude Code headless (`eval/lib/claude-plan.mjs`), never the API. Every turn is checked for required names, facts stated too early, and fact coverage; every question for avoided terms. Failures are regenerated with the reasons (twice), then the world is dropped; nothing is hand-edited. Claude outputs are cached in `writer-cache.json`, so rebuilding is free and reproducible.
- **Splits** by world: disjoint name pools (entity universe), disjoint seed ranges (history), disjoint question-style instructions (generation scenario). `build.ts` dedups questions and fails on cross-split near-duplicates (token Jaccard ≥ 0.8) or shared 8-word sequences between questions.
- **Owner review** (`review-cli.mjs`): a stratified sample, a local page to mark items, and the tally recorded in the split manifest.

```bash
npm run eval:stages:gen -- --split test --worlds 100      # also train (300), val (40)
node eval/stages/gen/review-cli.mjs page --split test     # open eval/stages/data/test/review.html
node eval/stages/gen/review-cli.mjs record --split test --verdicts ~/Downloads/review-verdicts.json
```

## Tracks (`tracks/`, `run.ts`)

One production replay per world (extraction Lambda in-process with real Gemini, the app's merge, `commit_notebook`, user actions through the app's RPCs) feeds three tracks:

- **Extraction:** entity precision/recall/F1 (name or unique first-name match), relation F1 as unordered entity pairs and typed (label equivalence judged by Claude on the plan), attribute recall.
- **Admission:** for each extracted entity that matches gold, whether the commit persisted it, merged it into the right or wrong entity, or rejected the whole turn.
- **End to end:** the replay's graph plus 50 background distractors, embedded, ranked by `retrieve-memory`; Gemini answers in text with the production Live prompt (read from `lib/logic/conversation_policy.dart`, pinned by hash) and the retrieved context; Claude judges correct / wrong / abstained. Each miss is attributed to the first stage that lost the answering entity.

- **Oracle retrieval** skips extraction and admission: the world's correct graph is written directly (one fixed description template), with the same distractors, and ranked in **hybrid** (production: embeddings + lexical) and **lexical-only** (no embeddings, retrieve-memory's own fallback) modes. Recall@1/5/10, MRR, NDCG@10 on answerable questions, with a paired hybrid − lexical difference.

Statistics: 2,000 bootstrap resamples of whole histories (questions about one history move together); every metric is reported with its 95% interval and sample size. Latency P50/P95 per stage is from the local stack.

```bash
source eval/privacy/local-env.sh
# serve functions as in eval/memory/README.md (EMBED_INTERNAL_SECRET), then:
export GEMINI_API_KEY=... STAGES_GEMINI_CALL_BUDGET=1500
npm run eval:stages -- --track all --split test           # resumable; --smoke for the 3-world check
```

Outputs: `eval/results/<date>-<sha>/stages/<split>/` — `worlds/<id>.json` (every per-item row), `summary.json`, `baseline-report.md`. The 48-probe suite (`npm run eval:memory`) is unchanged and remains the legacy regression suite.

## Limitations

- All data is synthetic. It is not real user speech and does not stand in for it.
- Extraction precision counts every extracted entity the gold doesn't label, including reasonable concept entities ("climbing"), so it understates precision.
- End-to-end answers are text with the context in the system prompt; production speaks through Gemini Live and fetches memory with a tool call.
- Oracle descriptions follow one template and read differently from extractor-written ones.
- One judge (Claude) per item; judge reasons are saved for review.

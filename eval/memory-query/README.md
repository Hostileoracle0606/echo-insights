# Memory query evaluation

This is a synthetic development set and an offline annotation scorer for MQ-07. The scorer makes no provider calls and changes no account or hosted service. The 12 cases were used in development probes. Reserve a separate set for the rollout comparison and have an independent reviewer check its passages, eligibility labels, answer keys, operations, and time scopes before running either variant.

`cases.json` contains matched current/previous/difference and proposed/confirmed cases, earlier facts, a multi-operand calculation, unsupported/wrong-role facts, conversation, clarification, and an ineligible source. Source IDs are local to each case. For fixed-passage tests give the model only eligible passages; keep ineligible examples available only to a controlled retrieval eligibility test. Do not put this synthetic door code or these passages into a real user's journal.

## Offline scoring

Run `python3 -m unittest discover -s eval/memory-query -v`. To score a run, create an observations JSON array with one object per case per variant, for example:

```json
[
  {
    "variant": "baseline",
    "case_id": "goal-current",
    "operation": "recall",
    "time_scope": "current",
    "status": "supported",
    "returned_source_ids": ["g2"],
    "judgments": {"retrieval": true, "evidence": true, "spoken": true},
    "latency_ms": 1200,
    "timeout": false,
    "fallback": false
  }
]
```

Run `python3 eval/memory-query/score.py observations.json`. This is an annotation format, not a production response or a claim that the example was run. Give every variant the same cases. Use `recall`, `confirm_event`, `calculate`, or `conversation` for operation; `current`, `previous`, `specified_period`, `comparison`, or `unspecified` for time scope. Normalize actual system labels to these categories and record the mapping alongside the results. Use `supported`, `insufficient_evidence`, `clarification`, or `conversation` for status. Record the actual returned source IDs, not the key. A system that does not expose a route or time scope cannot receive a pass for that stage: record an explicit unknown value. Source IDs not eligible for that case fail retrieval and evidence automatically.

Have a reviewer independently annotate each boolean, using the recorded result and the answer key, not knowledge of which variant produced it:

- **retrieval**: the eligible returned passages contain the necessary facts; for abstention/clarification, they provide appropriate context without an ineligible source; for conversation, no memory lookup is made.
- **evidence**: the verdict uses the passages with correct roles, time, and arithmetic and does not assert unsupported facts; a correctly justified abstention or clarification passes.
- **spoken**: the actual spoken response conveys the key answer or appropriate uncertainty/clarification, without contradicting evidence. Check the audio or its verified transcript, not just the tool verdict.

The report lists each stage per case and variant, overall stage pass counts, supported grounded answers (all stages pass), correct abstentions and clarifications (status and spoken both pass), p50/p95 using nearest rank, timeouts, fallbacks, and cases over 3,500 ms. A timeout fails every stage even if a late answer appears; record latency to timeout or completion, whichever happened first. The initial 3.5-second budget is a test target, not a demonstrated production guarantee. A two-variant report also shows paired grounded gains and losses on common cases; inspect missing IDs and require `complete: true` before comparing full-set totals. Use the detailed cases to identify routing, retrieval, evidence, and speech misses. With few cases p95 is unstable; report sample size and individual observations.

## Development probes

The live Decisions adapter matched the expected route and time scope on six synthetic questions. A separate five-question audio probe used Gemini Live, the local V3 handler, and Gemini 2.5 Flash with a simulated authorized database and stub embeddings. Live called the memory tool on all five. It said the goal increased by 50 levels and declined the unsupported gift question. It missed the current and previous goals and omitted the recorded coffee proposal on the first run. After evidence changes, targeted retests recovered the current goal at level 150, the previous goal at level 100, and the distinction between considering and making the coffee change. The coffee reply followed the grounded answer with a question that assumed the user was hesitating. Two attempts at the previous goal hit a provider rate limit. The handler now distinguishes provider failure from insufficient journal evidence.

These probes exercised the provider calls and the voice protocol. The paired held-out comparison and on-device voice run remain open.

## Safe live comparison and rollout evidence

1. Independently review the reserved comparison set before running either variant. Use an isolated test account and synthetic data. Record code versions, feature-flag configuration, model and instruction versions, environment, and fixture revision. Keep credentials and journal text out of operational logs.
2. First compare baseline and routed answer workflows with the same fixed eligible passages. Then separately run the actual client, tool, and retriever using normal Gemini Live instructions against the isolated synthetic account. Preserve paired case order or randomize it in a recorded way; use equivalent account state and shared latency boundaries for both variants. Capture the route, scope, fallback and source IDs through test instrumentation. The V3 account-wide request has `version: 3`, `scope: "user"`, `notebookId`, `question`, and `query`; the response includes `version`, `context`, `entityIds`, `quotes`, and `verdict` (`status`, `text`, `sourceIds`). Adapt only to the actual deployed contract and document any differences. A raw tool result alone is not an end-to-end spoken evaluation.
3. Measure elapsed time from the same user-turn boundary to the completed spoken response or deadline in each variant. Record provider timeout separately from fallback; annotate all results including failures and late responses. Blind reviewers to variant where feasible. Score using the observation schema above, preserving individual case evidence and reviewer decisions in a protected artifact.
4. Publish a paired report with sample size, case-level differences, grounded-answer gains/losses, abstention and clarification, stage misses, p50/p95, timeouts, fallbacks, and budget exceedances. Review regressions and explicitly decide acceptable thresholds before broad release. Tests of the scorer do not count as live evaluation.
5. The Flutter build and edge function both default `MEMORY_QUERY_ROUTING_ENABLED` to off. For a limited cohort, enable the Dart build define and the edge function environment variable. Provision `MEMORY_QUERY_GEMINI_API_KEY` in the edge function environment. In this mode Gemini Decisions receives the redacted question and Gemini 2.5 Flash receives that question and eligible passages. Review this data flow before authorization. Eligibility is rechecked before inference and before returning an answer or clarification that cites passages. An edit or Forget after the provider request begins can suppress its result but cannot withdraw content already sent.
6. Record the cohort, owner, and thresholds for grounded answers, abstention, and latency. To roll back, disable the flag on the server to stop V3 inference, then distribute a Flutter build with the flag off to restore the V2 tool for that cohort. Verify both steps in the test environment.

## Live reranker comparison

`reranker-live-cases.json` defines 40 questions across 20 fresh synthetic journal histories. `prepare-reranker-live.ts` replays their raw turns through extraction, the web merge, the `commit_notebook` RPC, and entity embedding. It saves completed account access privately and records whether each source turn produced a journal entry. The same synthetic accounts and question strings are used for all three arms.

Use a disposable local Supabase project and the optional local eval configuration in `retrieve-memory`. The Edge worker uses `MEMORY_QUERY_ROUTING_ENABLED=true`, `LUMEN_ENABLE_LOCAL_EVAL_ARMS=true`, and a loopback `LUMEN_EVAL_RERANKER_LOOPBACK_URL` such as `http://127.0.0.1:61428/score`. For the Docker Edge Runtime, the local-only adapter connects that port through `host.docker.internal`. The scorer is the saved pairwise MiniLM checkpoint served with `python -m validation.serve_reranker` from `ml/embedding`. Supply the same bearer token in `MEMORY_RERANKER_BEARER_TOKEN` and `LUMEN_RERANKER_BEARER_TOKEN`. Set the extraction and Decisions credentials using the dedicated Lumen evaluation key. Pass credentials through the runner environment and keep the account access file private.

Run `vite-node --config eval/memory/vite.config.ts eval/memory-query/prepare-reranker-live.ts FIXTURES OUTPUT_DIR` from the repo root with the disposable Supabase credentials and embedding secret in the environment. The preparer generates `trials.json` with cyclic arm ordering and `local-access.json` with temporary credentials. Set `LUMEN_LIVE_TRIALS`, `LUMEN_LIVE_RECORDINGS`, and `LUMEN_LIVE_ACCESS` to absolute paths, then run `flutter test --dart-define=MEMORY_QUERY_ROUTING_ENABLED=true test/lumen_reranker_live_probe.dart` with the explicit evaluation key. Set `LUMEN_LIVE_CONCURRENCY=3` to match the paired run. The probe uses the real Live prompt, tool formatter, retrieval client, and local V3 handler. It pins the question and lookup text so a changing Live tool hint cannot change the dense pool. It records the model's original tool arguments separately.

The experimental arms isolate the existing selector, dense-only candidate selection, and the identical dense list reordered by the trained scorer. Each tool result can carry a trace with hashed candidate IDs, linked entry IDs, and fallback status. For each arm, run the `rehearsal-status` question twice sequentially with `LUMEN_LIVE_CONCURRENCY=1`, first after starting a fresh Edge process and then on the same process. Leave the already loaded scorer running during these controls. For the fault control, stop the scorer, repeat the same question with `dense-pairwise`, and compare the trace's selected seeds with warmed `dense`. These controls are outside the paired quality cohort. Each schedule entry has `id`, `caseId`, `question`, `arm`, and `phase`.

Generate anonymized review rows with `python3 eval/memory-query/score-reranker-live.py blind FIXTURES RECORDINGS BLIND_OUTPUT`. Reviewers score factual correctness, temporal handling, entity attribution, uncertainty, and delivery from 0–2. Each grade contains `id`, `factual`, `temporal`, `attribution`, `uncertainty`, `delivery`, boolean `unsupported_recall`, and `reason`. Run `python3 eval/memory-query/score-reranker-live.py summarize FIXTURES RECORDINGS REPORT --grades GRADES --preparation PREPARATION` to join grades after review. Report capture completeness, strict spoken passes, the preregistered mean rubric score, candidate parity, latency percentiles and fallback frequency. Support-turn references and data-loss diagnostics are evaluator-only.

# Lumen metrics showcase — design

Date: 2026-11-17 · Status: draft, awaiting approval

## Intent

Produce credible, reproducible evidence of how Lumen behaves, to show
prospective employers. Three kinds of reader look at the same evidence:

- **AI/LLM engineering:** memory quality (does it remember the right thing,
  forget what it should, and know what it doesn't know).
- **Mobile/full-stack:** responsiveness, crash and network recovery, and
  account/privacy boundaries.
- **Product/founding engineer:** whether a newcomer understands what Lumen
  is, when it listens, and what it keeps.

Credibility is the product. A skeptical reviewer should be able to read the
method, see the raw runs, find honest failures, and rerun it with one command.

## Goals

1. One rerunnable eval suite covering the seven test areas in the brief.
2. Recorded metrics with sample sizes and run-to-run spread, tied to a commit SHA.
3. One results page: headline summary, a section per role, method, a
   failure gallery, and the reproduce command.

## Non-goals

- Fixing the bugs the suite finds. Record them; fixes are follow-ups. (If a
  fix lands before the report, show before/after, never just "after".)
- Load or scale testing beyond the "large history" case.
- Benchmarking against competitors.

## Anti-goals (failure even if it "works")

- Numbers from a mock or stub instead of the deployed pipeline.
- Cherry-picked runs, or re-running until a number looks good.
- Any real journal content, keys, or personal data in the report or repo.
- Metrics a reader can't trace back to raw run files.

## Constraints

- **Extraction** runs on `gemini-2.5-flash` (thinking off) behind
  `POST /v1/notebooks/{id}/extractions`, an AWS API Gateway route served by
  the Lambda in `infra/lambda/extract-graph` (Supabase-token authorizer,
  Gemini key in Secrets Manager, DynamoDB idempotency claims). Both Flutter
  and web call it. The handler is dependency-injected
  (`createExtractGraphHandler` in `core.mjs`), so the eval runs it
  **in-process** against local Supabase with an in-memory claim store and a
  Gemini key from the environment — same code path, no AWS deploy. The Supabase edge function
  `supabase/functions/extract-graph` still calls Groq but appears unused by
  either client — the eval must NOT target it, or it measures an extractor
  users never hit.
- **Voice** runs on Gemini Live. Free tier is 20 requests/day/model, which
  now binds both extraction and voice. A full memory run is ~360 extraction
  calls (≈40 scenarios × ~3 sessions × N=3) — about 18 days on the free tier.
  Model output is non-deterministic, so each scenario still runs several times.
- **Memory model today:** relations soft-delete via `superseded_at`; there is
  no first-class "tentative vs decided" field and no user-facing delete
  beyond row deletes. Several tests will likely surface gaps — an expected,
  reportable result.
- **Retrieval paths** to cover for resurfacing: lexical, semantic
  (`entity_embeddings`, gte-small), graph expansion, and the session-close
  brief / TTS opener.
- **Target: local Supabase (decided by owner).** Local stack on the
  shifted ports in `supabase/config.toml` (API 55321), migrations applied
  from `supabase/migrations`, edge functions served locally with
  `supabase functions serve`. Groq/Gemini calls still go to the real
  providers, so model behaviour is real; only the database and functions
  are local. Throwaway users and cleanup per run, as in the release gate
  (`RETRIEVAL_GATE_TARGET=local`). Never the live project. The report states
  that runs were against a local stack at a given commit, and the privacy
  matrix notes that platform-level settings (hosted auth config, function
  logs retention) were not exercised.
- **Repo location:** memory notes say the `~/Documents` checkout has iCloud
  pack corruption and `~/Developer/echo-insights` is canonical — confirm
  before committing work.

## Approaches considered

- **A. One suite, one report, role lenses (chosen).** Scripted scenarios
  replayed through the real functions, auto-scored, raw JSON per run; timing
  marks in the app; privacy checks grown from the release gate; manual
  device/first-use tests on a standard sheet. One body of evidence, every role.
- **B. Three tailored reports.** Sharper per role, but overlapping
  measurements and drift between reports.
- **C. Mostly manual.** Fast, but small-N hand runs won't survive an AI
  reviewer and can't be rerun.

A was picked: rerunnability is part of the pitch, and the suite stays useful
as Lumen changes.

## Design

### Track 1 — Memory quality (`eval/memory/`)

**Quota budget (owner chose free tier only).** Only extraction and spoken
answers spend Gemini quota; retrieval probes run on local gte-small
embeddings and cost nothing. So: extract each scenario's sessions **once**,
snapshot the resulting graph, then probe retrieval as many times as useful.
Budget: ~12 scenarios × ~2.5 sessions ≈ 30 extraction calls, spread over 2
days of gemini-2.5-flash quota. Spoken-answer checks use the separate Live
model quota: 5 scenarios, shared with responsiveness runs, so voice work is
scheduled across days. The report states N=1 for extraction and does not
claim run-to-run spread; it says so plainly as a limitation.

**Scenario corpus** (`eval/memory/scenarios/*.yaml`), 12 scenarios, each a
sequence of sessions of text turns followed by labeled probes:

```yaml
id: job-change-decided
category: changing_facts
sessions:
  - turns: ["I might leave Northwind, the commute is killing me."]
  - turns: ["Talked it over with Priya. I decided to stay at Northwind."]
probes:
  - ask: "What happened with the job thing?"
    expect_retrieved: [Northwind]
    expect_status: decided          # tentative | decided | superseded
    expect_order: [tentative, decided]
    expect_not_retrieved: [Priyanka] # similar-name distractor
```

Categories: continuity — indirect reference, paraphrase, ambiguous names
(4); correction (3); deletion (2); changing facts and conflicts, incl.
similar names (3). Each scenario carries several probes (~4), so ~50 scored
probes total from 30 extraction calls.

**Runner** (`eval/memory/run.mjs`, same pattern as
`scripts/retrieval-release-gate.mjs`): per run, create a fresh test user,
replay sessions through the extraction Lambda handler (in-process, see
Constraints) + notebook commit, then for each
probe call `retrieve-memory` and read back the derived brief. "After restart"
= a new client that rebuilds state only from the database. Extraction runs
once per scenario; the graph snapshot is saved so probes and scoring can be
rerun for free. Raw output: `eval/results/<date>-<sha>/memory/*.json`.

**Scored surfaces:** retrieval results (all paths), the derived brief, and —
for a 5-scenario subset only, because of Gemini quota — the spoken answer
transcript, scored by an LLM judge with a published rubric.

**Metrics:** recall@k and precision@k on labeled memories; unrelated-memory
insertion rate; stale-fact resurfacing rate after correction/deletion, split
by retrieval path; tentative/decided accuracy; sequence preservation rate;
ambiguity-acknowledged rate. Reported as counts over probes (e.g. "41/50"),
not percentages with false precision.

### Track 2 — System behaviour

**Responsiveness.** Add structured timing marks beside the existing
`vlog('timing', …)` calls in `journal_provider.dart`: process start → UI
interactive; tap → mic open; end of user speech → first assistant audio;
retrieval duration; whether background init overlapped an active turn.
Collect via `integration_test` on simulator and one physical device, across
network profiles (Wi-Fi, LTE, 3G via Network Link Conditioner) and seeded
history sizes (empty, ~50, ~500 entities). Report p50/p95 per stage as a
"where the person waits" breakdown.

**Interruptions and recovery.** Scripted where possible: terminate the
simulator app during transcription and during extraction/commit; drop the
network mid-turn; retry. Check: completed turns persisted, partial turn
dropped or marked, zero duplicate entries/entities/relations/briefs.
Physical-device kill and interrupting a spoken reply are run by hand on the
recording sheet.

**Privacy and account boundaries.** Extend the release gate into a matrix:
two test accounts × {no token, expired, malformed, other user's token} × each
edge function, each user table, and the three AWS Lambdas (authorizer,
live-session credential broker, extraction) run in-process. Plus: scan the built app bundle for
provider-key patterns; sample function logs and error responses for
conversation content. Output: a pass/fail matrix.

### Track 3 — First use

Protocol + observation sheet in `eval/first-use/`. 3–5 participants new to
Lumen, on a seeded test account. Tasks: talk through your day; find what it
kept; correct one error. Record: time to first successful turn, confusions,
and three comprehension checks (what is it for / is it listening now / what
will it keep). Consent noted; no participant content in the report, only
observations and quotes they approve.

### Report

One page in the repo (`docs/metrics/index.html`), also published as a
shareable link: headline numbers, a section per role, method and sample
sizes, a failure gallery with 3–5 worked examples, run date, commit SHA, and
the reproduce command.

### Build order

1. Privacy matrix (cheapest; extends the existing gate).
2. Memory corpus + runner + scorer (largest; quota-bound, start early).
3. Timing marks + responsiveness collection.
4. Recovery scripts + manual sheet.
5. First-use sessions.
6. Report page.

## Left to the builder

Exact scenario wording, scorer implementation, file layout inside `eval/`,
chart choices on the report page, which network-shaping tool to use.

## Assumed defaults (owner can override)

- First-use participants: 3 people the owner knows who haven't used Lumen.
- No hard deadline; roughly two weeks, with free-tier quota pacing the
  memory and voice runs.
- Implementation happens in `~/Developer/echo-insights` (the canonical
  checkout per earlier notes), verified before the first commit.
- Out of scope, noted as a follow-up: the Groq-backed edge function
  `supabase/functions/extract-graph` appears unused and could be removed.

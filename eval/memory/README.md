# Memory quality

Does Lumen remember the right thing, forget what it's told to, and keep up
when a fact changes? 12 scripted multi-session scenarios run through the
real extraction and commit path on a **local** Supabase stack. Retrieval and
the session-close brief are then probed and scored. All text is synthetic and
every name is invented.

| Category | Scenarios | What it checks |
|---|---|---|
| continuity | 4 | indirect reference, paraphrase, two people with the same first name (twice) |
| correction | 3 | wrong city fixed in the same session, wrong title fixed next session, description edited by the user |
| deletion | 2 | `remove_entity` on a project (then mentioned again), `forget_entity` on a person |
| changing_facts | 3 | tentative → decided, decided → reversed, similar names (Priya / Priyanka) |

48 probes in all. Scenarios live in `scenarios/*.json`; `scenario.mjs` validates them.

## How it runs

Two phases, with a saved snapshot between them, because extraction spends
Gemini free-tier quota (20 requests/day/model) and probing mostly doesn't.

**Extract** (`--phase extract`): spends quota and resumes across days. For each scenario with no saved snapshot:
1. Create a fresh `memory-eval-*@example.test` user.
2. Replay each turn through the production pieces both clients share. This is a composite, not one client's exact path:
   - save the turn as the Flutter app does (`lib/services/transcript_store.dart`);
   - reload `get_notebook_snapshot`, so every session is a client rebuilt from the database;
   - build the extraction context with the web app's `retrieveMemory` and `compileExtractionContext` (`src/lib/turn-state/web-adapter.ts`). Recent conversation holds the user's earlier lines in the session only; there are no Lumen replies in a scripted replay;
   - build the runtime request body (as PR #35's `toRuntimeContext` and the Flutter client do);
   - call the **extraction Lambda in-process**, authorizer first, real `gemini-2.5-flash`. This is the route Flutter uses, and web after PR #35;
   - run the web app's `mergeExtraction` with the follow-up dropped, as the web adapter does;
   - commit with `commit_notebook`.

   A turn whose extraction fails or whose commit is rejected is recorded in `lostTurns` and the scenario carries on, as the app does. Only a quota stop aborts a scenario.
3. Between sessions, run the scripted user actions through the same RPCs the app's memory controls call (`edit_entity_description`, `remove_entity`, `forget_entity`). Forget runs **without** transcript erase, which is the app's default, so the saved transcript and journal entries keep the name.
4. Save the graph as `graphs/<id>.json`. Owner ids become placeholders, and a sha256 digest makes drift detectable.

The run stops cleanly at `MEMORY_CALL_BUDGET` or at the first 429, with no retry. A scenario that stops partway saves nothing and restarts from its first session on the next run.

**Probe** (`--phase probe`) restores each snapshot into a fresh user.

- Generate the session-close brief through the brief Lambda using the scenario graph. Cache Gemini text by snapshot digest and stub the TTS call.
- Add the same 50 synthetic background entities to each notebook. Run `embed-entities` (local gte-small) until it confirms that zero rows remain.
- Call `retrieve-memory` in notebook scope for each probe. Score ranked entity IDs at the first 1, 3, and 8 positions. Check stale content in the full context string returned by the service as well.

Then it scores and writes `memory.json`.

The Groq edge function `supabase/functions/extract-graph` is never called.

```bash
source eval/privacy/local-env.sh                 # local stack only (assertLocalTarget)
memory_edge_dir=$(mktemp -d /tmp/lumen-memory-edge.XXXXXX)
# CLI 2.75 cannot serve the checked-in v5 lockfile. Serve a disposable copy.
git archive HEAD supabase | tar -xf - --exclude='supabase/functions/retrieve-memory/deno.lock' -C "$memory_edge_dir"
(umask 077; printf 'EMBED_INTERNAL_SECRET=%s\n' "$(openssl rand -hex 24)" > "$memory_edge_dir/functions.env")
supabase functions serve --workdir "$memory_edge_dir" --no-verify-jwt --env-file "$memory_edge_dir/functions.env" &
set -a; . "$memory_edge_dir/functions.env"; set +a
export GEMINI_API_KEY=...                        # free tier
npm run eval:memory -- --phase extract           # resumable; run again tomorrow
npm run eval:memory -- --phase probe             # rerun freely; briefs are cached
```

These environment variables control spending and pacing:

| Variable | Default | What it does |
|---|---|---|
| `MEMORY_CALL_BUDGET` | 18 | Maximum provider calls per Pacific day, extraction and briefs together. Spend is logged in `eval/results/memory-quota-log.json`. |
| `MEMORY_CALL_INTERVAL_MS` | 7000 | Spacing between provider calls, for the free tier's per-minute limit. |
| `MEMORY_RESUME_AFTER_429` | unset | Set to `1` to allow more calls on a day that already logged a 429. |

Tests: `node --test eval/memory/*.test.mjs` (the snapshot round trip runs only with the local-stack env set) and `npx vitest run --config eval/memory/vite.config.ts` (replay).

## Scoring (`score.mjs`)

All metrics are counts over probes. Text is compared as whole words, ignoring case and punctuation.

- **recall@1 / @3 / @8** counts expected names found in the first 1, 3 or 8 ranked entities. Expected names missing from the graph count separately as **extraction misses** and are excluded from recall denominators.
- **precision@3 / @8** counts labeled hits among the ranked items after excluding explicitly labeled related names. **Unrelated insertions** count retrieved background entities. Other same-story items are reported separately.
- **stale resurfacing:** a removed, forgotten or corrected thing (`expect_not_retrieved` names, `stale_text`) appearing in retrieval or in the brief.
  - **Retrieval** counts a forbidden entity name in the ranked items as resurfacing even when nearby text denies the old fact. It also checks for asserted stale text in the retrieved items and service context. The service returns one ranked list, so path attribution is `combined`.
  - **Brief** is tallied once per scenario with an available brief and applicable stale check. Text matching uses rules for common explicit negations, including “Dalton, not Dayton.”
  - **Vacuous checks** are reported apart and not counted. A check is vacuous when the scripted action didn't apply (for example, its entity was never extracted), or when, with no action, a name-only check names something never in the graph.
- **distractor confusion:** a look-alike name (`distractors`, e.g. Priya / Priyanka) that is retrieved. This is scored apart from stale resurfacing, because a look-alike isn't a stale fact.
- **tentative/decided:** `decided` is correct when a retrieved description or active relation contains a decided marker and none contains a tentative or old marker. Lumen has no tentative/decided field, so this scores what the stored text says.
- **sequence preserved:** the latest state is in active retrieved text, and every earlier state survives as a *statement*: a description, a relation, or a superseded relation kept as history. A leftover bare entity name doesn't count. This rule was tightened after the first results, because the first version passed on the name alone.
- **ambiguity acknowledged:** two distinct retrieved entities share the ambiguous first name, meaning they weren't merged into one person.

## Claude as judge (`judge.mjs`, `--phase judge`)

Stale facts, decided/correct status, sequence and ambiguity need reading, not
word matching, so their reported numbers come from **Claude only**
(`claude-opus-5-5`, structured JSON output, effort `high`). Recall, rank and
precision stay deterministic set comparisons. Gemini never judges, so the
model that wrote the memory never grades it.

- **Input:** the scenario script as ground truth (every turn and memory action, in order), the probe question, and the retrieved items from the scenario (background distractors are left out). For briefs: the script and the brief text, once per scenario.
- **Applicability** comes from the probe labels, not the judge: a check the probe doesn't make is forced to `n/a`, and an applicable check the judge leaves unanswered counts as a failure, never a pass.
- **Calibration:** 8 hand-labelled cases (`judge-calibration.mjs`) run first on every judge run. They cover a denial that isn't stale, a stale brief, stale and clean retrieval, sequence kept and lost, and two same-named people kept apart or merged. If any disagrees, the run still writes verdicts but marks `calibrated: false`. Rubric v1 disagreed on one case (status with both the old and corrected city live). The rubric was made explicit that any live contradicting statement makes status wrong, matching the scorer's existing status rule. v2 agrees 8/8.
- **Cost and caching:** about 45 calls (~55k input / ~7k output tokens, ≈$0.40) for 8 scenarios. Verdicts are cached by a hash of model, rubric and input in `judgments.json`, with each verdict's one-sentence reason.
- **Rule agreement** with the old word-matching rules is reported in `memory.json` (`method.judge.ruleAgreement`), never scored.

```bash
source eval/privacy/local-env.sh
export ANTHROPIC_API_KEY=...
npm run eval:memory -- --phase judge   # judges the newest probes.json
```

## Judged results, November 24, 2026

Same 8 scenarios and 32 probes as November 19 (`probes.json` unchanged),
re-scored with Claude as the judge; calibration 8/8.
[Scores](../results/2026-11-24-b266bda/memory/memory.json) ·
[Verdicts and reasons](../results/2026-11-24-b266bda/memory/judgments.json)

| | Rule-based (Nov 19) | Claude judge (Nov 24) |
|---|---|---|
| Stale in retrieval | 3/10 | **3/10** |
| Stale briefs | 1/3 | **2/3** |
| Decided/correct status | 2/3 | **2/3** |
| Sequence preserved | 2/2 | **0/2** |

Where they differ:
- **Brief after forget** (`deletion-forget-person`): the name is gone, but the brief still says "had lunch with someone who is thinking about moving to Oslo". Claude counts the forgotten person's details as live memory; the word rules only looked for the name.
- **Sequence** (`changing-decided-then-reversed`): both trips are retrieved side by side with no statement that Lisbon came first and was cancelled. The old rule passed because both names were present.

**Extraction blocked, November 24.** The four pending scenarios (two same-first-name cases, the next-session job-title correction, tentative-to-decided) could not be extracted: Gemini answers `402 prepayment credits are depleted` for the paid key. The Lambda reports that as a per-turn `providerUnavailable`, so the first attempt saved four empty graphs; those were deleted. `providerFetch` now treats a provider 401/402/403 as an account stop like a 429, so the run ends and saves nothing.

## Partial results, November 19, 2026

The local run scored **8 of 12 scenarios and 32 of 48 retrieval probes**.
Five scenarios had cached briefs. Gemini returned HTTP 429 during extraction,
leaving four scenarios to replay and three saved scenarios awaiting briefs.
The JSON report links each probe to its source snapshot and extraction commit.
[Scores](../results/2026-11-19-9d35e9a/memory/memory.json) ·
[Raw probes](../results/2026-11-19-9d35e9a/memory/probes.json) ·
[Extraction log](../results/2026-11-19-80a36bd/memory/extract-log.json)

| | Continuity | Correction | Deletion | Changing facts | Total |
|---|---|---|---|---|---|
| Probes scored | 8 | 8 | 8 | 8 | **32** |
| Recall@1 | 1/5 | 5/8 | 2/4 | 3/9 | **11/26** |
| Recall@3 | 3/5 | 7/8 | 3/4 | 6/9 | **19/26** |
| Recall@8 | 5/5 | 8/8 | 3/4 | 7/9 | **23/26** |
| Extraction misses | 4/9 | 0/8 | 0/4 | 0/9 | **4/30** |
| Precision@8 | 5/64 | 8/64 | 3/64 | 8/64 | **24/256** |
| Stale retrieval | – | 3/4 | 0/6 | – | **3/10** |
| Stale briefs with an applicable check | – | 1/2 | 0/1 | – | **1/3** |
| Decided/correct status | – | 2/3 | – | – | **2/3** |
| Sequence preserved | – | – | – | 2/2 | **2/2** |
| Distractor confusion | – | – | – | 1/2 | **1/2** |

The top eight covered the whole notebook in 0 of 32 probes. The scorer counted
184 background items across those 32 probes and zero vacuous stale checks.
Both same-first-name scenarios, the next-session job-title correction, and the
tentative-to-decided scenario are pending. Ambiguity has zero scored checks.

The November 18 reports remain available as historical evidence from the
smaller graphs and earlier scorers.

### Findings

1. **A same-session correction fixes the relation but not the descriptions** (`correction-city-same-session`). After "Dayton … sorry, Dalton", Lumen's graph has the right active relation (`Imogen --moved_to--> Dalton`, with the Dayton relation superseded). But Imogen's description still reads "moved to Dayton", and a `Dayton` entity remains whose description is "Imogen moved to Dayton". Retrieval hands both to the voice model in 3 of 4 probes, and the `decided` status check fails.
2. **A user-edited description doesn't reach the session brief** (`correction-edit-description`). After the user corrects Felix from "pediatric nurse" to "physical therapist" with `edit_entity_description`, retrieval is right everywhere (status 2/2). But the brief, written from the saved transcript, says "Felix Navarro is a pediatric nurse".
3. **Forget: the scored surfaces are clean, but the name survives elsewhere** (`deletion-forget-person`).
   - **Clean:** after `forget_entity("Dana Whitfield")`, neither retrieval nor the brief contains "Dana Whitfield" or "Whitfield" (0/3 probes, 0/1 brief). The brief said "someone".
   - **Not scored, from the snapshot:** the stored question "Why is Dana considering Oslo?" survives on the Oslo entity. Entity questions feed the brief prompt, and the suppression covers the two-word name, not "Dana" alone. The journal entry and transcript also keep the full name, because forget ran without transcript erase.
4. **A rejected graph commit can discard a whole turn's memory** (`continuity-paraphrase`). On replay, Gemini emitted relations referencing the undeclared entity `training`. The commit rejected the whole patch as `invalidChange`. The runner saved the patch in `lostTurns`, then continued to the next session. All four labeled extraction misses came from this scenario.
5. **Continuity ranked the target first in 1 of 5 findable cases.** Corrections ranked it first in 5 of 8. One of two similar-name checks surfaced the look-alike.

## Limitations

- **N = 1** extraction per scenario (free-tier quota). No run-to-run spread is claimed; the model runs at temperature 0, but output can still vary.
- Local stack at a given commit; Gemini is the real provider.
- Path attribution is `combined` (see above).
- Stale, status, sequence and ambiguity are judged by one model (Claude) once per input, checked against 8 hand-labelled cases. Its verdicts and reasons are in `judgments.json` for review; no second human rater has checked them.
- Spoken answers (an LLM judge over Live transcripts) are not covered yet. That needs Live quota scheduling and is planned separately.
- Snapshots carry the throwaway user's random suppression key (`suppressionKey`). Forget hashes are keyed per user, and a restored forget needs that key to keep redacting the name. The key protected only the synthetic names in these files, and its user is deleted.

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

**Probe** (`--phase probe`): restores each snapshot into a fresh user, then:
- runs `embed-entities` (local gte-small);
- calls `retrieve-memory` for every probe (`scope: notebook`, `k = 8`);
- writes the session brief once per scenario through the real brief Lambda. The text call is real Gemini, cached by snapshot digest; TTS is answered by a stub because audio isn't scored.

Then it scores and writes `memory.json`.

The Groq edge function `supabase/functions/extract-graph` is never called.

```bash
source eval/privacy/local-env.sh                 # local stack only (assertLocalTarget)
mv supabase/functions/retrieve-memory/deno.lock /tmp/   # lockfile v5 vs CLI 2.75, see eval/privacy/README.md
printf 'EMBED_INTERNAL_SECRET=%s\n' "$(openssl rand -hex 24)" > /tmp/functions.env
supabase functions serve --no-verify-jwt --env-file /tmp/functions.env &
set -a; . /tmp/functions.env; set +a
export GEMINI_API_KEY=...                        # free tier
npm run eval:memory -- --phase extract           # resumable; run again tomorrow
npm run eval:memory -- --phase probe             # rerun freely; briefs are cached
mv /tmp/deno.lock supabase/functions/retrieve-memory/deno.lock
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

- **recall@1 / @3 / @8:** expected names found within the first 1, 3 or 8 retrieved entities. The scored graphs hold 3–6 entities, so `k = 8` returned the **whole graph in 20 of 20 probes**. That makes recall@8 a check that the entity exists, not of ranking: read recall@1. An expected entity that extraction never produced counts as an **extraction miss** and is left out of every recall denominator.
- **precision@8 / unrelated insertions:** retrieved entities that answer the probe, and the rest. Low by construction when `k` exceeds the graph size.
- **stale resurfacing:** a removed, forgotten or corrected thing (`expect_not_retrieved` names, `stale_text`) appearing in retrieval or in the brief.
  - **Retrieval** covers entity names, descriptions, active relations and the context string the voice model gets. `retrieve-memory` returns one ranked list and doesn't say whether the lexical, semantic or graph path found an item, so this surface is reported as `combined` rather than guessed. With `k` ≥ graph size, a stale *entity* that still exists always surfaces, so read this as "the stale fact is still in memory".
  - **Brief:** tallied **once per scenario**, since there is one brief per scenario.
  - **Vacuous checks** are reported apart and not counted. A check is vacuous when the scripted action didn't apply (for example, its entity was never extracted), or when, with no action, a name-only check names something never in the graph.
- **distractor confusion:** a look-alike name (`distractors`, e.g. Priya / Priyanka) that is retrieved. This is scored apart from stale resurfacing, because a look-alike isn't a stale fact.
- **tentative/decided:** `decided` is correct when a retrieved description or active relation contains a decided marker and none contains a tentative or old marker. Lumen has no tentative/decided field, so this scores what the stored text says.
- **sequence preserved:** the latest state is in active retrieved text, and every earlier state survives as a *statement*: a description, a relation, or a superseded relation kept as history. A leftover bare entity name doesn't count. This rule was tightened after the first results, because the first version passed on the name alone.
- **ambiguity acknowledged:** two distinct retrieved entities share the ambiguous first name, meaning they weren't merged into one person.

## Results so far (2026-11-18, `eval/results/2026-11-18-9a89931/memory/memory.json`)

**Partial:** 5 of 12 scenarios have been extracted (20 of 48 probes, at least one scenario per category).
- **Failed:** `continuity-paraphrase` (a commit was rejected; see finding 4).
- **Pending:** the other 6, for the next quota day.

`eval/results/2026-11-18-f4e7de1/` is the same probes under the scorer before the review fixes, kept for comparison.

| | continuity | correction | deletion | changing facts | **total** |
|---|---|---|---|---|---|
| probes scored | 4 | 8 | 4 | 4 | **20** |
| recall@1 | 0/5 | 5/8 | 1/2 | 1/5 | **7/20** |
| recall@3 | 5/5 | 8/8 | 2/2 | 5/5 | **20/20** |
| recall@8 (k ≥ graph in 20/20) | 5/5 | 8/8 | 2/2 | 5/5 | **20/20** |
| extraction misses | 0/5 | 0/8 | 0/2 | 0/5 | **0/20** |
| precision@8 | 5/24 | 8/24 | 2/12 | 5/16 | **20/76** |
| stale probes (any surface) | – | 4/4 | 0/3 | – | **4/7** |
| … stale in retrieval | – | 3/4 | 0/3 | – | **3/7** |
| stale briefs (per scenario) | – | 2/2 | 0/1 | – | **2/3** |
| decided/correct status | – | 2/3 | – | – | **2/3** |
| sequence preserved | – | – | – | 2/2 | **2/2** |
| ambiguity acknowledged | – | – | – | – | 0/0 (two-Sams/two-Alexes pending) |
| distractor confusion | – | – | – | – | 0/0 (similar-names pending) |

No stale check was vacuous in this run.

### Findings

1. **A same-session correction fixes the relation but not the descriptions** (`correction-city-same-session`). After "Dayton … sorry, Dalton", Lumen's graph has the right active relation (`Imogen --moved_to--> Dalton`, with the Dayton relation superseded). But Imogen's description still reads "moved to Dayton", and a `Dayton` entity remains whose description is "Imogen moved to Dayton". Retrieval hands both to the voice model in 3 of 4 probes, and the `decided` status check fails.
2. **A user-edited description doesn't reach the session brief** (`correction-edit-description`). After the user corrects Felix from "pediatric nurse" to "physical therapist" with `edit_entity_description`, retrieval is right everywhere (status 2/2). But the brief, written from the saved transcript, says "Felix Navarro is a pediatric nurse".
3. **Forget: the scored surfaces are clean, but the name survives elsewhere** (`deletion-forget-person`).
   - **Clean:** after `forget_entity("Dana Whitfield")`, neither retrieval nor the brief contains "Dana Whitfield" or "Whitfield" (0/3 probes, 0/1 brief). The brief said "someone".
   - **Not scored, from the snapshot:** the stored question "Why is Dana considering Oslo?" survives on the Oslo entity. Entity questions feed the brief prompt, and the suppression covers the two-word name, not "Dana" alone. The journal entry and transcript also keep the full name, because forget ran without transcript erase.
4. **Extraction can lose a whole turn** (`continuity-paraphrase`). `commit_notebook` rejected the merged change as `invalidChange` on day 1, when the runner still aborted the scenario. The likeliest cause is a relation to an entity the model didn't declare. The runner now records it as a lost turn, with the undeclared endpoints, and carries on; the next extract run will show which endpoint it was.
5. **Ranking rarely puts the answer first for indirect questions:** recall@1 is 0/5 for continuity (the target is typically ranked 2nd or 3rd) against 5/8 for corrections.

**Scorer caveat:** of the 2 stale briefs, the Imogen brief says "Dalton, not Dayton". It counts as stale because word matching can't see the negation. The other is finding 2.

## Limitations

- **N = 1** extraction per scenario (free-tier quota). No run-to-run spread is claimed; the model runs at temperature 0, but output can still vary.
- Local stack at a given commit; Gemini is the real provider.
- Path attribution is `combined` (see above).
- Text markers are blunt: they can't tell "not Dayton" from "Dayton". Raw retrieval and brief text for every probe is in `probes.json`, so each score can be checked by hand.
- Spoken answers (an LLM judge over Live transcripts) are not covered yet. That needs Live quota scheduling and is planned separately.
- Snapshots carry the throwaway user's random suppression key (`suppressionKey`). Forget hashes are keyed per user, and a restored forget needs that key to keep redacting the name. The key protected only the synthetic names in these files, and its user is deleted.

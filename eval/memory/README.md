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
2. Replay each turn the way the web app does (`src/lib/turn-state/web-adapter.ts`):
   - save the turn as `lib/services/transcript_store.dart` does;
   - reload `get_notebook_snapshot`, so every session is a client rebuilt from the database;
   - run local lexical `retrieveMemory` and `compileExtractionContext`;
   - build the runtime request body (as PR #35's `toRuntimeContext` and the Flutter client do);
   - call the **extraction Lambda in-process**, authorizer first, real `gemini-2.5-flash`;
   - run `mergeExtraction` with the follow-up dropped, as the web adapter does;
   - commit with `commit_notebook`.
3. Between sessions, run the scripted user actions through the same RPCs the app's memory controls call (`edit_entity_description`, `remove_entity`, `forget_entity`).
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

- **recall@8:** expected names found among the retrieved entities. An expected entity that extraction never produced counts as an **extraction miss** and is left out of the recall denominator, so extraction failures and retrieval failures stay separate.
- **precision@8 / unrelated insertions:** retrieved entities that answer the probe, and the rest. The graphs are small (3–6 entities), so `k = 8` often returns the whole graph and precision is low by construction. Read it as "how much else comes along", not as a ranking-quality score.
- **stale resurfacing:** a removed, forgotten or corrected thing (`expect_not_retrieved` names, `stale_text`) appearing in retrieval (entity names, active relation text, descriptions, the context string the voice model gets) or in the brief. Counted per surface. `retrieve-memory` returns one ranked list and doesn't say whether the lexical, semantic or graph path found an item, so the retrieval surface is reported as `combined` rather than guessed.
- **tentative/decided:** `decided` is correct when a retrieved description or active relation contains a decided marker and none contains a tentative or old marker. Lumen has no tentative/decided field, so this scores what the stored text says.
- **sequence preserved:** the latest state is in active retrieved text, and every earlier state is still somewhere in what retrieval returns.
- **ambiguity acknowledged:** two distinct retrieved entities share the ambiguous first name, meaning they weren't merged into one person.

## Results so far (2026-11-18, `eval/results/2026-11-18-f4e7de1/memory/memory.json`)

**Partial:** 5 of 12 scenarios have been extracted (20 of 48 probes, at least one scenario per category). The other 7 resume on the next quota day.

| | continuity | correction | deletion | changing facts | **total** |
|---|---|---|---|---|---|
| probes scored | 4 | 8 | 4 | 4 | **20** |
| recall@8 | 5/5 | 8/8 | 2/2 | 5/5 | **20/20** |
| extraction misses | 0 | 0 | 0 | 0 | **0/20** |
| precision@8 | 5/24 | 8/24 | 2/12 | 5/16 | **20/76** |
| stale resurfacing (probes) | – | 4/4 | 0/3 | – | **4/7** |
| … in retrieval | – | 3 | 0 | – | **3** |
| … in the brief | – | 4/4 | 0/3 | – | **4/7** |
| decided/correct status | – | 2/3 | – | – | **2/3** |
| sequence preserved | – | – | – | 2/2 | **2/2** |
| ambiguity acknowledged | – | – | – | – | 0/0 (two-Sams/two-Alexes not yet extracted) |

### Findings

1. **A same-session correction fixes the relation but not the descriptions** (`correction-city-same-session`). After "Dayton … sorry, Dalton", Lumen's graph has the right active relation (`Imogen --moved_to--> Dalton`, with the Dayton relation superseded). But Imogen's description still reads "moved to Dayton", and a `Dayton` entity remains whose description is "Imogen moved to Dayton". Retrieval hands both to the voice model in 3 of 4 probes, and the `decided` status check fails.
2. **A user-edited description doesn't reach the session brief** (`correction-edit-description`). After the user corrects Felix from "pediatric nurse" to "physical therapist" with `edit_entity_description`, retrieval is right everywhere (status 2/2). But the brief, written from the saved transcript, says "Felix Navarro is a pediatric nurse".
3. **Forget holds in both surfaces** (`deletion-forget-person`). After `forget_entity("Dana Whitfield")`, neither retrieval nor the brief mentions her (0/3).
4. **Extraction can lose a whole turn** (`continuity-paraphrase`, not scored yet). `commit_notebook` rejected the merged change as `invalidChange`, so nothing was saved. The likeliest cause is a relation to an entity the model didn't declare, which the RPC rejects outright. The runner now records the turn and the undeclared endpoints; the next extract run will show which.

**Scorer caveat:** in finding 1, the brief's "Dalton, not Dayton" counts as stale because word matching can't see the negation. Of the 4 brief-stale probes, 3 come from that one brief; the 4th is finding 2. The rule was fixed before results existed and isn't adjusted after the fact.

## Limitations

- **N = 1** extraction per scenario (free-tier quota). No run-to-run spread is claimed; the model runs at temperature 0, but output can still vary.
- Local stack at a given commit; Gemini is the real provider.
- Path attribution is `combined` (see above).
- Text markers are blunt: they can't tell "not Dayton" from "Dayton". Raw retrieval and brief text for every probe is in `probes.json`, so each score can be checked by hand.
- Spoken answers (an LLM judge over Live transcripts) are not covered yet. That needs Live quota scheduling and is planned separately.
- Snapshots carry the throwaway user's random suppression key (`suppressionKey`). Forget hashes are keyed per user, and a restored forget needs that key to keep redacting the name. The key protected only the synthetic names in these files, and its user is deleted.

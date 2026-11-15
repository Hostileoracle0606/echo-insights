# Pseudonymization spike (LM-55 / LM-56)

Date: 2026-11-07 · Branch: `spike/pseudonymization` · Model: `gemini-2.5-flash`

## Verdict: GO, for the fake-name variant only (small sample)

The run is complete: 16 extraction calls (4 transcripts x 4 variants) and 4 re-identification calls. Applying the criteria exactly as fixed in advance, the `fake` variant passes all six; `plain` and `role` fail on entity recall and entity precision. The sample is 4 transcripts (35 expected entities, 25 expected relations), so each percentage point is about a third of an entity; read it as "no evidence against fake names", not as proof.

| Criterion (fixed in advance) | Needed | fake | plain | role |
|---|---|---|---|---|
| Entity recall within 5 points of raw (62.9%) | at least 57.9% | 85.7% pass | 28.6% fail | 37.1% fail |
| Entity precision within 5 points of raw (66.7%) | at least 61.7% | 71.4% pass | 41.7% fail | 54.2% fail |
| Relation recall within 10 points of raw (72.0%) | at least 62.0% | 84.0% pass | 80.0% pass | 84.0% pass |
| Swap-back restores 100% of known placeholders | 100% | 117/117 pass | 66/66 pass | 66/66 pass |
| No known name in any prompt | 0 | 0 pass | 0 pass | 0 pass |
| Duplicates no worse than raw (0) | at most 0 | 0 pass | 0 pass | 0 pass |

Quota: after the first run was stopped by two 429s, the script was changed to pace calls at least 15 s apart, and on a 429 to wait the returned retry delay once (up to 90 s) and retry once, stopping at once if the reported `quotaId` names a per-day quota. The two original 429s were logged before the script recorded `quotaId`, so I cannot say which quota they hit. In the second run no 429 occurred at all in the 12 paced requests, which supports the coordinator's reading that it was a per-minute limit. The ledger is `tool/spike_pseudonymization/cache/ledger.jsonl` (22 lines: 2 rejected, 20 answered, counting both runs).

## Method

- Everything is synthetic. No real user data, no database, no deploys. Code: `tool/spike_pseudonymization/` (`swap.mjs` the swapper, `run.mjs` the harness, `fixtures/`, `cache/`, `results.json`).
- The real `granularPrompt` and `extractGraphFunction` are imported from `infra/lambda/extract-graph/prompts.mjs`. `buildUserMessage` in `core.mjs` is not exported, so it is copied in `run.mjs` (same text, minus the unused follow-up section). The request body copies the Lambda's: `tool_config` forced to `extract_graph`, temperature 0, thinking budget 0. The app uses `mode: 'granular'`, so that prompt is tested.
- Fixtures: 4 voice-style transcripts, a 13-entity synthetic graph (aliases, roles, descriptions, 5 existing relations) and a hand-written ground truth (`fixtures/ground_truth.json`).
  - People with aliases: Samantha / Sam / Sammy / "my sister"; Priya; a non-Latin name (美咲 / Misaki).
  - Names that are also words: Will, June, Rose, with traps ("Will you remind me", "in June", "the heat rose").
  - Employers and small towns (Halvorsen Marine Instruments, Kestrel Bioworks, Gardiner, Wiscasset); public entities kept (Boston Marathon, Python, Chicago, Osaka).
  - Quasi-identifiers (only chronometer calibrator in town, a March date) in t1 and t4; unknown new names (Teodor, Ingrid) the swapper cannot know.
  - t3 has ASR misspellings: Pria, Samatha, Halverson, Kestral Bioworks, Wil, Gardner, Mizaki.
- Swapper (`swap.mjs`): an entity list with aliases; exact match longest-first; fuzzy match on spelling (edit distance plus Soundex, windowed for multi-word names, dictionary words excluded); context rules for Will/June/Rose (capitalised, not a month or auxiliary verb); relational aliases ("my sister") are not swapped; public entities are not swapped. The map is in memory. The same swap is applied to the utterance, `EXISTING ENTITIES` (names and descriptions), `EXISTING RELATIONS` and `RECENT CONVERSATION`. Output is swapped back with a parser tolerant of dropped role suffixes.
- Variants: `raw`; `plain` (`[person:7]`); `role` (`[person:7 · sister]`, `[place:1 · town]`); `fake` (consistent invented names, alias-aware, for example Sam to Nor).
- Scoring (pooled over transcripts, raw counts shown):
  - Entities: a name resolves to a ground-truth entity by normalised alias (including the ASR spellings). Precision = distinct matched truth entities / returned entities, with unmatched ones counted as false positives. Recall = matched / expected.
  - Relations: matched on the unordered endpoint pair; labels ignored.
  - Duplicates: an existing entity returned under a different spelling, or the same entity returned twice.
  - Swap-back: share of placeholders in the output restored to the original name. "Exact" means the issued token came back verbatim; "lenient" means a parseable variant (role suffix dropped). The share counts both.
  - Leaks: known private spellings (names, aliases, ASR variants) found in the dynamic part of the prompt, with the word-trap strings masked.
- Criteria (fixed in advance): GO needs a variant with entity recall and precision each within 5 points of raw, relation recall within 10, swap-back 100%, zero known names in the prompt, and no more duplicates than raw.

## Results

Pooled over 4 transcripts, raw counts in brackets. Swap-back "exact" is the issued token returned verbatim; "lenient" is a parseable variant (for example the role suffix dropped). The swap-back share counts both.

| Variant | Entity precision | Entity recall | Relation precision | Relation recall | Duplicates | Swap-back (exact / lenient / failed) | Known names in prompt | Input round trip | Secondary: entity covered as row or relation endpoint |
|---|---|---|---|---|---|---|---|---|---|
| raw | 66.7% (22/33) | 62.9% (22/35) | 36.0% (18/50) | 72.0% (18/25) | 0 | n/a | n/a | n/a | 97.1% (34/35) |
| plain `[person:7]` | 41.7% (10/24) | 28.6% (10/35) | 37.0% (20/54) | 80.0% (20/25) | 0 | 100% (27 / 39 / 0) | 0 | 4/4 | 97.1% (34/35) |
| role `[person:7 · sister]` | 54.2% (13/24) | 37.1% (13/35) | 38.9% (21/54) | 84.0% (21/25) | 0 | 100% (3 / 63 / 0) | 0 | 4/4 | 97.1% (34/35) |
| fake names | 71.4% (30/42) | 85.7% (30/35) | 39.6% (21/53) | 84.0% (21/25) | 0 | 100% (117 / 0 / 0) | 0 | 4/4 | 100% (35/35) |

The last column is **secondary** (added after seeing the first two transcripts). It does not enter the verdict.

How to read it:
- The tag variants fail the entity criteria mainly because the model uses a placeholder as a relation endpoint without listing it as an entity row. The secondary column shows no information was lost (97.1%, the same as raw), but the criterion as written counts rows, and I did not change it.
- Fake names pass in part because the model re-lists every known name (42 returned entities against 33 for raw). Their recall is above raw. A GO that depends on "more rows than raw" is a weaker GO than it looks; entity precision (71.4% vs 66.7%) is the fairer signal and it is level to slightly better.
- Relation precision is low for every variant (36% to 40%); the prompt asks for dense, weak relations and my ground truth is short. Only the comparison between variants means anything.
- Misspellings (t3): the swapper caught all 8 ASR spellings (Pria, Halverson, Samatha, Kestral Bioworks, Wil, Gardner, Mizaki) in every non-raw variant, with 0 duplicates in all four variants. Raw also had no duplicates: Gemini corrected the misspellings itself from the entity list, so the "misspelling leaks and creates a duplicate" risk did not show up on the raw side, and the spike can only show that the swap did not make it worse.
- Prompt checks (no model): zero known private spellings in the dynamic prompt for any transcript and variant, Will/June/Rose traps untouched, and every input restored exactly on the round trip. Unknown new names (Teodor, Ingrid) are not swapped because the spike has no name recognition; that is the expected, documented gap.
- Static prompt collision: the shipped system prompt contains the example "it's Sam" (and "Maya"), which collides with the alias Sam. It is static and identical in every variant so it is excluded from the leak count, but it is a literal known name in a prompt; a production version should rename the example.

## Re-identification (fake variant, 4 calls)

The model was shown each pseudonymized prompt (utterance plus context) and asked who the author is and where they live or work. In all four answers it repeated the substitute names ("a chronometer calibrator at Brightwater Optics in Millbrook, Maine") and said the author's name is not stated. No real person, employer or town name appeared in any answer (checked automatically against every real spelling). Limits of this test: the real employer and towns are fictional, so a model could not recover them from general knowledge anyway; and what it did report is what remains: the rare job, the region ("Maine" is in the existing-entity descriptions and was not swapped) and the date. So this shows the swap holds against a model reading the text, not that the text is anonymous.

## Failure examples

- Tags are not re-listed as entities. In t2 the `plain` and `role` runs returned Teodor, ladder, gutter, June and Sunday, and used `[person:6]`, `[person:1]` and the others only as relation endpoints. In t4 `plain` and `role` listed none of June, Gardiner, Wiscasset, Rose, Halvorsen, Will or Python as rows. Raw skipped the same existing entities on t4 (7 missed), and fake skipped 5.
- A spurious "June" entity appeared in t2 under plain, role and fake (not raw): the month "in June" became a person row. Raw produced a relation `user -> June` instead, so it is not entirely new, but placeholders seem to push the model toward person-shaped rows.
- Role tags came back without their role suffix in 63 of 66 uses, so the extra tokens bought nothing; the lenient parser handles it. Placeholders also came back with underscores inside names (`analyst_job`), which the prompt's own examples encourage.
- Every variant, raw included, returned non-entities the ground truth does not list ("March fourteenth shipment", "ladder", "gutter", "Sunday"), which caps precision for all of them equally.
- Remaining swap gaps: t3 `Wil` for Will is swapped only because it is a mid-sentence capitalised non-dictionary word one edit from a known name; the same rule skips sentence-initial candidates, so a misspelled name at the start of a sentence would leak.

## Recommended variant

`fake`. It is the only variant that passes the fixed criteria, it swapped back with no repair (117 of 117 exact), and it needs no output-format discipline from the model. Plain tags are the fallback if fake names turn out to cause trouble, but with the current criteria they would not pass.

Costs the spike did not measure: a name generator that respects gender, script and uniqueness (and never collides with a real name in the user's graph or with the prompt's own example names); the risk that the model treats a plausible fake name as a real person and invents facts about it (not observed here); fake names appearing in generated prose that the user later reads, which must be swapped back every time.

## What a production version needs

- Client-side map. Keep the map on the device only, encrypted with the Keychain (LM-55). Persist it per entity: canonical name, aliases, fake name, tag number, role. Never send it, and never log placeholders alongside real names.
- New names. Detect them on the device (Apple NaturalLanguage), assign a placeholder at once and persist it before the call, so the result can be swapped back. A miss leaks that name but should not break extraction. The spike did not measure NER.
- Fuzzy matching. Reuse the thresholds from `swap.mjs` (edit distance 1 for 4+ letters, 2 with matching Soundex for 5+, windowed matching for multi-word names, dictionary words excluded). It caught all eight ASR spellings here, but the sample is tiny and the false-positive rate on a real graph is unknown. Name-words (Will, June, Rose) need the context rules and only apply when the graph knows them as a person.
- Card and brief calls. Extraction was the only call measured. The close-session card and drafts and session-brief send longer text and generate prose with names; they need the same swap with swap-back before saving. Check that fake names do not appear in generated prose that the user later reads.
- Swap-back parser. Accept tag forms without brackets or role suffixes, and fail closed: an unknown placeholder must not be saved as an entity name.
- Voice path. Gemini Live receives the raw audio and real names, so none of this covers voice. The text calls would be pseudonymized while the voice session is not; the privacy copy (LM-53) must say so. Opener audio either gets generated on the device from the swapped-back text or the TTS call receives the real name.
- Interaction with Forget's redaction (same branch). Forget removes entities and their mentions; the map must be redacted in the same transaction (delete the entity's aliases and placeholders), or the map becomes a record of someone the user asked Lumen to forget. Cached extraction results on the server hold placeholder text only, which should help: the Lambda's 7-day idempotency cache never sees a real name. Redaction must also not reuse a placeholder number for a different entity while old results are still cached.
- Hidden costs. Prompt tokens grow slightly (role tags are long), and the shipped prompt's example names need to change.

## Limits of this spike

- 4 transcripts, one run each at temperature 0, counts of 25 to 54 items per cell. Differences of a few points are noise, and the entity-row metric rewards re-listing known names.
- The ground truth was written by one person (me), relation matching ignores labels, and the entity-resolution alias lists include the ASR spellings.
- The fixtures are small and synthetic; real graphs have up to 20 context entities and far messier text. Only extraction was measured; the card and brief calls were not.
- Re-identification was one prompt per transcript against a fictional world, see above.
- The criteria and metric definitions were not changed after seeing data; the "entity covered" column was added as secondary, and the retry/pacing logic was added to the script after the first quota stop.

## Reproduce

`node tool/spike_pseudonymization/run.mjs` (cached; use `--dry` to audit prompts without calls). A fresh run needs 16 extraction calls and 4 re-identification calls, paced 15 s apart.

## Honesty notes

- The first run stopped at a 429 after 8 extraction calls. I then reran the script once more (to add the secondary diagnostic), which sent one more request that was also rejected, before the coordinator's instruction arrived. Total: 22 requests, 20 answered (16 extraction + 4 re-identification), 2 rejected.

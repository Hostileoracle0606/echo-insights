# Externalized context: session record (21–22 Nov 2026)

What we changed on `feat/externalized-context`, why, and what each change
did when tested. All code is uncommitted on the branch. Server changes are
deployed to the `lumen-staging` Supabase project only; production is
unchanged.

The tickets are in [externalized-context-tickets.md](externalized-context-tickets.md),
and the manual test scripts are in [ec-01-test-scripts.md](ec-01-test-scripts.md).

## Summary

| Area | Before | After |
|---|---|---|
| Long sessions | Gemini's sliding-window compression decides what to drop | Behind a flag: a rebuild from saved context at a pause, 299–533 ms, no audible reset |
| Extraction | Free-tier key: 429s, 38–75 s per turn, 0 entities merged | Paid key through a local runtime: 1–4 s per turn |
| Leaving a session | Waited on stuck extraction: 3.5 min, four attempts | Under 1 s |
| Filler words | "um", "uh" saved, extracted, and able to become graph entities | Removed before saving, extraction and the graph |
| Repetition | Lumen kept returning to one person | Lumen gets what it already raised; memory only when the user refers back |
| Memory recall | About 25 of 41 entities for any query | 1–6 close matches, or nothing |
| Test environment | Production database, missing 6 migrations | `lumen-staging`, fully migrated, with a test account |

## Where we started

- **Live session.** One Gemini Live connection per session
  (`gemini-3.1-flash-live-preview`), with `context_window_compression`
  (sliding window) and session resumption. Gemini reads seeded context
  (`client_content`) only before its first reply. After that, new context
  can arrive only through a tool response or a new connection.
- **Memory.** One tool, `get_relevant_memory`. It ran the general graphloop
  retriever: keyword hits with no minimum score, plus exact names, plus
  semantic matches (`gte-small` embeddings, at least 0.7). It then expanded
  two hops and ranked by relevance, recency, importance and confidence,
  keeping 24 entities. Both the prompt and the tool told Lumen to use memory
  whenever it would "sound like you remember".
- **Extraction.** Ran on the AWS notebook runtime, using `gemini-2.5-flash`
  with the key from the AWS secret `echo-insights/gemini-api-key`.
- **Graph summary.** Built when a connection opens. The prompt described a
  `probedThisSession` field ("DO NOT re-ask about these"), but the app never
  sent it. `recentAgentQuestions` held the *first* 8 lines Lumen said, not
  the latest.
- **Noise filter.** Dropped pronouns, time words, and "lumen" (so the
  assistant doesn't record itself).
- **Database.** Production was missing six migrations from Phases 1 and 2,
  including `conversation_turns.context_text`.

## Decisions, in order

### 1. Externalize context rather than rely on one long session

**Decision.** Structured graph records become the single source of truth.
Each Live connection gets a small, deduplicated context built from them.
Direct questions are answered by deterministic fact tools. The transcript
stays the store of record and is never searched to answer. Written up as
EC-01 to EC-11.

**Why.**
- Compression drops facts invisibly.
- A transcript keeps old and new values side by side ("200", then "350").
- Typed records remove interpretation at question time.
- Fact lookups take milliseconds, where passage extraction takes 1–1.5 s.

**Constraints the user set.**
- No citations are spoken.
- Extraction errors are fixed through a correction flow: the user objects,
  Lumen asks, corrects, and reads it back for confirmation.
- The conversation must still feel natural, with low latency and
  continuity. That made EC-01 the gate for everything else.

### 2. EC-01: rebuild the session at a pause, behind a flag

**Decision.**
- `CONTEXT_REBUILD_ENABLED` turns compression off. Once a turn budget
  (`CONTEXT_REBUILD_MAX_TURNS`) or a maximum age is reached, the session is
  rebuilt through the existing fresh-reconnect path: drop resumption, hold
  the mic, new token, reconnect, seed recent turns and the graph summary.
- It rebuilds only when nobody has the floor.
- Off the record never rebuilds, because rebuilt context comes only from
  saved turns.

**Why.** The existing Forget path already did a fresh reconnect safely.
Rebuilding at a pause hides the reconnect. The age limit replaces
compression's protection against Gemini's ~15-minute limit.

**Outcome.**
- Simulator, typed turns: seeded in 395 ms. First plain reply after the
  rebuild took 742 ms, against 933–1,008 ms before it.
- Found live: typed-only conversations never rebuilt, because the composer
  pauses the mic and the policy required `live`. Fixed with a regression
  test.
- Spoken runs, 7 rebuilds in total: seeded in 299–533 ms. The first reply
  after a rebuild (1,033–1,324 ms) fell within the range of other
  memory-tool replies (1,103–1,670 ms). No re-greeting, and the thread
  continued.

### 3. Test scripts and a helper

**Decision.** Spoken dialogue scripts with expected behaviour for each turn,
plus `scripts/ec01-rebuild-test.sh`. It builds, installs, saves logs, starts
the local runtime, and summarises reply latency around each rebuild.

**Why.** One typed run is not a latency distribution, and a listening check
needs repeatable scripts.

### 4. Diagnosing the first spoken run

The first spoken run (against production) showed slow exit, graph updates
not landing, "um" in the graph, and recall needing repeated questions.

| Symptom | Cause found |
|---|---|
| Graph updates not landing | Extraction returned 429 from the free-tier Gemini key: 72 s to fail, 38 s when it succeeded, 0 entities merged |
| 3.5-minute exit | Leaving waits up to 15 s for queued extraction, which was taking 40–75 s |
| Cards, briefs, saved transcripts failing | Production missing six migrations (`context_text`) |
| Savings goal needed repeated asking | Not the router: the tool was called each time. The facts had never reached the graph |

### 5. Filler words: strip at turn finalization

**Decision.**
- `stripFillers` removes "um", "uh", "er", "erm", "hmm" and "mm", with the
  commas or ellipses around them, from user turns when they are finalized.
- A turn of nothing but fillers is not saved or extracted.
- Words that can carry meaning stay: "like", "well", "you know", "uh-huh",
  "mm-hmm".
- Separately, the graph noise filter now rejects filler words as entity
  names.
- The web reducer got the same change, with the same test cases.

**Why.** Finalization is the one point every downstream use passes through:
saved transcript, extraction, graph, and rebuild replay. Filtering only the
graph would still leave "um" in quotes and replayed turns. The two reducers
are meant to stay identical.

**Outcome.** A staging test turn, "Um, my sister Priya is, uh, moving to
Lisbon next month.", was stored as "My sister Priya is moving to Lisbon
next month."

### 6. Gemini key: test before switching

**Decision.**
- The key in `echo-insights/.env` (the "Lumen project credentials") returned
  `GenerateRequestsPerDayPerProjectPerModel-FreeTier`, so extraction was not
  switched to it.
- The user then supplied a paid key. 21 calls inside a minute raised no
  429, which is above the free tier's 10 per minute. It went into `.env` as
  `GEMINI_API_KEY`, never into a `VITE_` variable, which would be bundled
  into the web build.

**Why.** Switching to a free-tier key would not have fixed anything. A
burst above the free rate limit is the cheapest proof of tier.

**Still open.** The AWS secret needs `aws login` before it can be updated.
The key was pasted in chat, so it should be rotated after testing.

### 7. Staging as the test environment

**Decision.** Run Simulator tests against `lumen-staging`, not production.
- **Migrations:** staging already had all 37 from main, plus 10 from
  `feat/release-beta-forget`, so there was nothing to apply.
- **Functions and secrets:** deployed `retrieve-memory`, `embed-entities`,
  `extract-graph` and `speak-agent`. Set `EMBED_INTERNAL_SECRET` and the
  vault entries the embedding trigger needs. Without the vault entries, the
  trigger silently skipped embeddings.
- **Runtime:** the AWS runtime is tied to production, so
  `scripts/local-runtime.mjs` now accepts one explicitly named test project
  (`LOCAL_RUNTIME_TEST_PROJECT`). It always refuses the production ref. It
  uses the paid key from `.env`, without touching AWS.
- **Build config:** `.env.staging` (gitignored) holds the staging URL, the
  publishable key, and the runtime at `127.0.0.1:8787`.
- **Test account:** a confirmed account, with credentials in the gitignored
  `.env.staging-account`.
- **Briefs:** the brief route was missing from the local runtime, so every
  brief returned 404. Added it.

**Outcome.** Extraction took 1–4 s, exit took 0.1–0.7 s, and a brief was
written in 0.9 s plus 3.3 s for audio.

### 8. Why Lumen fixated on one person

Session 3 raised Priya three times after the user said "move on". Four
causes:

1. **Rebuilds look like a session opening.** A rebuild sends opening context
   plus "this continues an earlier conversation", and the opening rule says
   to pull on a thin entity by name. Lumen called memory on **5 of 5** first
   replies after a rebuild.
2. **No list of what was already raised.** `probedThisSession` was promised
   but never sent, and `recentAgentQuestions` kept the first 8 lines, not the
   latest.
3. **No rule for pushback.** Complaining about Priya also created a thin
   Priya entity, which the question rules then target.
4. **Memory held almost only Priya,** and the prompt encouraged recall "to
   sound like you remember".

**Decision: implemented 2 and 4.**
- `probedThisSession` now lists names Lumen has said this session, from the
  graph and from memory results. Memory results matter because Priya came
  from another notebook.
- `recentAgentQuestions` keeps the latest 8 lines.
- The prompt and the tool description say to call memory only when the user
  refers back or asks what they said. They also say never to bring up
  something memory returned that the user didn't ask about. The web copy
  was updated to match.

**Found by the tests.** The live conversation keeps only its last 16 turns,
so a topic raised early dropped out of the list. Lumen's lines are now
recorded for the whole session.

**Not done.** Cause 1 (rebuild should send a continuation, not an opening)
and cause 3 (drop a topic after pushback).

### 9. Recall that listed everything

After the edits, "Where were we with the project before?" got a list: the
launch checklist and Samsung work. The scoping was set by the user: fix this
failure, not redesign recall in general.

**Causes, confirmed by replaying queries against staging.**
- **No Lumen entity.** The noise filter drops "lumen", so the user's app
  had no entity. The session saying "Lumen should be out by mid December"
  saved 0 entities.
- **Retrieval returned most of the graph.** About 25 of 41 entities for any
  query, ordered almost at random: `Europe` and `BBC` for "project", a
  Samsung quote for "Lumen".

**Decision: meaning decides what the live tool returns.** A new selection
step in `retrieve-memory/select.ts`, used only by the live tool:
- **Match:** semantic score of at least 0.7, a full name in the query
  (score 1), or the query as part of a name (0.9).
- **Keep:** matches within 0.06 of the best, at most 3, best first.
- **Add:** the best match's direct neighbours, at most 3.
- **No match:** returns nothing.
- **Description words:** never qualify on their own.

**Why there.**
- The graphloop code is vendored from `src/lib/graphloop`, and a sync check
  fails on drift, so the change belongs in the Lumen-specific function.
- Extraction's notebook-scope lookups keep the old ranking.
- On a new account, recency and importance are nearly equal everywhere.
  They added noise instead of separating results.

**Outcome on staging.**

| Query | Before | After |
|---|---|---|
| "Samsung work" | about 25 | `samsung`, `ai` |
| "Lisbon move" | about 25 | `lisbon`, `priya` |
| "launch" | about 25 | `launch` |
| "project" | about 25 | 4 |

Two older tests for memory after a Forget expected "Priya" to find "Priya
Nair", which is how partial-name matching was added. The user reports the
recall issue as resolved.

### 10. Simulator confusion

Two Simulators were booted: iPhone 17 had an Oct 31 production build, and
iPhone 17 Pro had the staging build. The local runtime also stops whenever
a Claude session ends, which silently stops extraction.

**Decision.** Test on the iPhone 17 Pro, and restart the runtime before each
run with `scripts/ec01-rebuild-test.sh runtime`.

## Files

**App (Flutter)**
- `lib/logic/context_rebuild_policy.dart` (new) — when to rebuild.
- `lib/logic/filler_words.dart` (new) — `stripFillers`.
- `lib/logic/session_topics.dart` (new) — `probedThisSession`,
  `recentLines`.
- `lib/logic/turn_state.dart` — strips fillers from user turns at
  finalization.
- `lib/logic/noise_filter.dart` — filler words as entity names.
- `lib/logic/conversation_policy.dart` — memory-tool guidance.
- `lib/providers/journal_provider.dart` — rebuild wiring, session topic
  record, tool description.
- `lib/services/gemini_live_client.dart` — compression switch.
- `lib/env.dart` — rebuild defines.

**Web**
- `src/lib/turn-state/filler-words.ts` (new), `reducer.ts`.
- `src/lib/conversation-policy.ts`, `src/routes/index.tsx`.

**Server**
- `supabase/functions/retrieve-memory/select.ts` (new), `handler.ts`.

**Tooling**
- `scripts/local-runtime.mjs` — named test project, brief route.
- `scripts/ec01-rebuild-test.sh` (new).
- `.gitignore` — `test-runs/`.

**Tests**
- `test/context_rebuild_policy_test.dart`, `test/filler_words_test.dart`,
  `test/session_topics_test.dart`, `test/memory_tool_guidance_test.dart`
  (all new).
- Additions to `test/off_the_record_test.dart` and
  `test/gemini_live_client_test.dart`.
- `src/lib/turn-state/filler-words.test.ts` (new).
- `supabase/functions/retrieve-memory/select.test.ts` (new), plus additions
  to `handler.test.ts`.

**Docs**
- `docs/externalized-context-tickets.md`, `docs/ec-01-test-scripts.md`, this
  file.

## Test status

- **Flutter:** 1,183 pass. Three failures also fail on `main`:
  - two in `journal_session_lifecycle_test.dart` about briefs;
  - one in `off_the_record_test.dart` about the opener.

  `journal_typed_turn_test`'s "mulling it over" failed once under the full
  run and passed in isolation 3 of 3 times. It looks timing-sensitive.
- **Analyzer:** clean.
- **Web:** turn-state and `src/lib` suites pass.
- **retrieve-memory (Deno):** 42 pass, and type-checks cleanly with its own
  import map.
- **Pre-existing and unrelated:**
  - The graphloop sync check reports drift in `communities.ts`, which
    matches `origin/main`.
  - A root-level Deno type check fails on `graphology` types in the same
    file.

Every change was test-first: the tests failed before the change and pass
after it.

## Open items

1. **Lumen-name filter.** Keep "Lumen" when it is a project or product, so
   facts about the app attach to an entity.
2. **Rebuild context.** Send a continuation note, not opening context, so
   Lumen does not reach into memory after every rebuild.
3. **Pushback.** Drop a topic for the session after "move on" or "why do
   you keep…", recorded so it survives a rebuild (EC-04).
4. **Broad recall.** Add a list of past sessions from session cards to the
   opening and rebuild context.
5. **Reply shape for recall.** State the fact, tie it to now, ask what
   changed since then.
6. **Extraction quality.** Garbled speech becoming entities (`BBC`), wrong
   relations (`Priya → North America`), abstract and emotion entities, and
   inconsistent snake_case names.
7. **Stutters.** Collapse repeated words ("on on", "It's It's") in the
   filler step.
8. **Leaving a session.** Close the screen at once and let queued work
   finish in the background, rather than waiting 15 s on extraction.
9. **Production.**
   - Apply the six missing migrations, with an explicit go-ahead.
   - Update the AWS secret to the paid key once `aws login` is fresh.
   - Rotate the key pasted in chat.
10. **EC-10.** Measure from the end of speech, not from transcript arrival.
    Spoken latencies currently read as near zero.
11. **Staging cleanup.** Two sessions on the test account show "live now"
    because their close failed while the runtime was down.

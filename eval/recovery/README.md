# Interruptions and recovery

Does a turn survive the network or the process dying at each durable step,
without leaving duplicates? Three parts:

| Part | What breaks | How | Output |
|---|---|---|---|
| Fault matrix | network before a request, lost response, process kill, two devices racing, a retried close | `npm run eval:recovery` | `recovery.json` |
| Simulator kill | the iOS app, killed by the OS mid-turn and relaunched | `eval/recovery/kill.sh` | `recovery-kill.json` |
| Hand runs | a real iPhone swiped away, airplane mode, talking over Lumen | `manual-sheet.md` → `record-manual.mjs` | `recovery-manual.json` |

Results land in `eval/results/<date>-<sha>/`. Everything runs against local
Supabase only, and **no model is called**: recovery measures persistence, so
extraction and brief requests are answered by a stub with synthetic patches
(`fixtures/patches.json`). A guard under the stub counts any request that would
leave the machine; every report records it, and it must be 0.

## Fault matrix

Each scenario: a fresh test user, three typed turns, a fault on turn 2, then a
**restart**: a new client that knows only the database and the device's turn
journal, finishes what it can, and says turn 3. Then the audit.

| Fault | What happens to turn 2 |
|---|---|
| `extract_before` | the extraction request never leaves |
| `extract_lost_ack` | the extractor finishes, its response is lost |
| `commit_before` | the `commit_notebook` request never leaves |
| `commit_lost_ack` | the server commits, the response is lost |
| `kill_after_journal` | the process dies at extraction (odd seeds: after the extractor answered; even: before the request left) |
| `kill_after_extract` | the process dies at the commit (odd seeds: after the server applied it; even: before it left) |
| `concurrent_commit` | two devices at the same revision each commit a turn naming the same new person |
| `brief_lost_ack` | closing the session: the brief is saved, the response lost, the app retries |

**What runs is the app's own code.** The client is the web app's turn machine,
pipeline and web adapter (`src/lib/turn-state/`), its merge
(`mergeExtraction`) and `commitNotebook`, run under vite-node. Only the ends
are swapped: the browser Supabase client becomes one whose `fetch` injects the
fault (`supabase-shim.ts`, `faults.mjs`); the turn journal lives in a
per-device store that outlives the "process", as localStorage outlives a
killed tab; and extraction goes to the API Gateway route both apps use, served
by the real extraction Lambda and authorizer in-process (`stub-lambdas.mjs`).
The brief is the real `close-session` brief handler. A killed client is simply
abandoned with its request never settling.

**Audit** (`audit.mjs`), with the service role so RLS hides nothing. A
duplicate is any row beyond the first with the same key: `journal_entries`
(notebook, text; the table has no turn id and every eval turn's text is
unique), `entities` (notebook, lower(name)), live `relations` (notebook,
source, target, label), `conversation_turns` (notebook, turn id),
`session_briefs` (source notebook).

**Per run:** `completed_turns_kept` (n/of), `partial_turn`, duplicates per table.

| `partial_turn` | meaning |
|---|---|
| `recovered` | turn 2 committed exactly once (the journal resumed it, or the retry was deduplicated) |
| `marked` | turn 2's transcript is in `conversation_turns` but it never reached the graph |
| `dropped` | turn 2 is nowhere |
| `duplicated` | some turn is in the graph twice |
| `lost_completed` | a turn that had finished is missing |

A run **passes** when every completed turn is kept and there are no
duplicates, and turn 2 ends the way its fault requires (`judge` in
`scenarios.ts`): only the extraction faults may leave it `marked` or
`dropped`. A kill must be finished from the turn journal, a lost commit by a
deduplicated retry, a race by a rebase, each with exactly one model call for
turn 2; a retried close must come back `unchanged` with no second brief. A run whose
fault never fired is `not_triggered`: inconclusive, never a pass. For
`concurrent_commit` "fired" means a real revision conflict was observed.

**Seeds.** Each fault runs with seeds 1–10. Each step makes exactly one request,
so there is little timing to vary inside it: the seed adds 0–24 ms of jitter
before turn 2 (and between the two racing devices), and picks the kill variant
by parity. Ten passing seeds mostly show the behaviour is deterministic; they
are not ten independent samples of a noisy process.

### Results (`2026-11-18-c7f4f66/recovery.json`)

Every fault passed 10 of 10 under the per-fault rule above. (The first run,
`2026-11-18-376a330`, used a looser rule that only asked for no loss and no
duplicates; it also passed 80/80 and is kept as it was.) In both: no duplicate row in any table, every completed
turn kept, 0 real provider calls (260 stub). In detail:

- Lost commit response: the retry reused the request id and the server
  ledger replayed it. Turn 2 is in the notebook once.
- Kill at extraction or at the commit: the restarted client found turn 2 in the
  journal and finished it, with **one** model call in total. A kill after the
  extractor had answered was served from the claim store, not re-extracted.
- Two devices: all 10 runs hit a real conflict; the later device rebased and
  "Imre" exists once.
- Brief: the retried close returned `unchanged`, no second model call, one row.

**Worth knowing:** both extraction faults land as `marked`, not `recovered`.
When extraction fails or its response is lost, the turn machine drops the turn
(`durableExtractionFailed` → `dropHead`) and never retries, even though on a
lost response the extractor finished and the claim store holds the result.
The user's words survive in `conversation_turns`, but turn 2 never reaches
their notebook. The spec counts that as a pass ("dropped or marked"); it is
still a gap a retry would close.

### Run

```bash
supabase start                      # local stack; edge functions not needed
npm ci
source eval/privacy/local-env.sh
npm run eval:recovery               # RECOVERY_SEEDS=1 / RECOVERY_FAULTS=a,b to narrow
```

Exit 0 only when every run passed, 0 real provider calls, and every
`recovery-eval-*@example.test` user it made is deleted.

## Simulator kill test

`kill.sh` drives `integration_test/recovery_kill_test.dart` on its own
simulator ("Recovery Eval iPhone", created if missing). Five runs per case,
each on a fresh user:

- **transcription**: after turn 1 is committed, the fake Live server streams
  part of turn 2's input transcription and nothing finalizes it; the app is
  killed 0–1200 ms later.
- **extraction**: turn 2 is typed and sent; the app is killed 0–1800 ms after the
  gateway logs that turn 2's extraction began (the gateway holds each
  extraction response 2 s, so the kill lands inside it: a commit is a few ms, too short to aim at from outside the simulator).

`simctl terminate` kills the app; the script then runs the test again in
`resume` phase, which reopens the notebook (replaying the on-device turn
journal) and waits for it to drain. Then the same audit.

Real: the `JournalNotifier` and its turn machine, the on-device turn-journal
file, Supabase (local) for `commit_notebook` and `conversation_turns`, and
extraction through the app's own `ExtractGraphService` to
`NOTEBOOK_RUNTIME_URL`, where `gateway-server.mjs` runs the real extraction
Lambda (stubbed model). Fake: the Gemini Live socket and its token, the
microphone and the speaker. A typed turn in the app needs an open Live
session, so this is the only way to run one with no provider spend.

The plan times the kill from the app's `[lumen-timing]` extraction mark. That
mark isn't on this branch, so the gateway's own log line is the anchor and the
delays are fixed. A kill that lands after turn 2 has fully committed (nothing
left in the journal at relaunch) is `not_triggered`.

### Results (`2026-11-18-288df1a/recovery-kill.json`)

On an iPhone 17 simulator, 5 of 5 passed in each case, no duplicates:

- **transcription**: 5 of 5 `dropped`. A turn still being transcribed when the
  app died left nothing behind (no journal checkpoint, no transcript row, no
  half entry). Turn 1 kept every time.
- **extraction**: 5 of 5 `recovered`. Every relaunch found turn 2 in the turn
  journal (1 checkpoint), extracted and committed it once, and drained.

The gateway answered 20 model requests from the stub (turns 1 and 2 of each run) and made 0 real calls.

```bash
supabase start && source eval/privacy/local-env.sh
eval/recovery/kill.sh 5
```

## Hand runs

`manual-sheet.md` has the protocol and the table: physical-device kill,
airplane mode mid-turn, interrupting a spoken reply, 3 runs each. Fill rows
as you run them, then `node eval/recovery/record-manual.mjs`. It accepts only
enum outcomes and a note of at most 140 characters, and reports blank rows as
pending.

## Limits

- No model is called, so this says nothing about extraction quality; it
  measures what survives.
- The fault matrix drives the **web** client's pipeline. The iOS app has its
  own (Dart) turn machine; the simulator kill test covers it for kills, not for
  the network faults.
- The eval client writes `conversation_turns` at finalization the way the iOS
  app does; the web app doesn't write that table, so on web an extraction fault
  is `dropped` where this reports `marked`.
- The brief is requested with v1 (the server reads the transcript); the iOS app
  uses v2 (write, then speak). Both end in the same `save_session_brief` check.
- `session_briefs` and `conversation_turns` cannot hold duplicates by schema
  (primary keys); their zeros are structural.

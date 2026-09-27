# Voice session lifecycle: plan

Date: 2026-09-27. Branch: `feat/voice-session-lifecycle`, off `main` at `4d9843f`.

## Goals

1. **Connect once per sign-in, not per notebook.** The AWS credential exchange
   and Gemini setup happen in the background as soon as the user is signed in.
   Opening a notebook or tapping the mic claims a connection that is already
   up.
2. **A new notebook opens with Lumen.** The first time a notebook opens,
   Lumen's greeting plays automatically. The page shows a loading state until
   Lumen is connected, so the user never lands on a half-ready screen.
3. **An old notebook opens quietly.** No session starts on its own. The user
   sees the existing graph and the previous transcript. Tapping the mic picks
   up where the conversation left off: no greeting, and Lumen has the earlier
   context.
4. **The mic pauses and resumes.** Tapping the mic mid-session pauses it and
   tapping again resumes. Only the End button ends the session. No action
   ever creates a notebook the user didn't ask for.

## Constraints found in the current code

| Fact | Where | Consequence |
| --- | --- | --- |
| A Gemini token opens exactly one connection (`uses: 1`), must be used within 60 s (`newSessionExpireTime`), and the session can last up to 30 min | `infra/lambda/live-session/core.mjs` | A token can't be minted at sign-in and stored. What stays up from sign-in is the connection, refreshed with a new token each time |
| The token isn't tied to a notebook; the route only checks the notebook exists and belongs to the user | same | A user-scoped route (no notebook) is a small, safe runtime change |
| The system instruction is fixed when the connection is set up | `gemini_live_client.dart` | A connection opened at sign-in knows nothing about any notebook. Notebook context has to be sent after it's claimed |
| A connection that has held a conversation carries that conversation | Gemini Live semantics | A connection used in notebook A must never be handed to notebook B. After a claim, a fresh blank one is warmed |
| Gemini closes connections after about 10 minutes (`goAway`); the app refreshes warm connections every 9 min | `warm_budget.dart` (`refreshAfter`) | The sign-in standby is refreshed on the same schedule, limited by the existing budget |
| The audio player's `init()` can stall on the simulator, and `dispose()` waits behind it | `pcm_player.dart`, `journal_provider.dart` | The player moves to app level: initialised once, never disposed mid-session. This removes the 5 s wait and the lifecycle hang |
| Both speakers' turns are saved only in local app storage (`TurnJournalService`); Supabase keeps graph and entries but not Lumen's side | `turn_journal_service.dart`, migrations | An old transcript is viewable only on the device that recorded it (decision D1) |
| The mic button calls `endSession()` = `leaveNotebook()`, which sets `ended_at`; the next start inserts a new notebook | `journal_screen.dart`, `journal_provider.dart:1477`, `supabase_service.dart:23` | Replaced by pause/resume; notebooks are only created from the dashboard |

## Architecture

Two layers with one hand-off point:

```
 ┌──────────────────────── App level (lives for the signed-in user) ────────────────────────┐
 │                                                                                          │
 │   VoiceStandby                                     AudioOutput                           │
 │   · mints a user-scoped token                      · one PcmPlayer, initialised at       │
 │   · opens + sets up one BLANK Gemini connection      sign-in, reused by every session    │
 │   · refreshes it before goAway (budgeted)          · plays the bundled greeting          │
 │   · claim() hands it out, then warms a new one                                           │
 │                                                                                          │
 └──────────────────────────────────────┬───────────────────────────────────────────────────┘
                                        │ claim(notebookId)  → connected, blank session
 ┌──────────────────────────────────────▼───────────────────────────────────────────────────┐
 │   Notebook level (JournalNotifier, one open notebook)                                    │
 │   · loads graph + previous transcript                                                    │
 │   · runs the notebook session state machine (below)                                      │
 │   · on first live use: sends the notebook context, then opens the mic                    │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flows

### Flow 1: app-level standby (from sign-in)

```
                  sign in / app resumed / user interacts (budget refilled)
   ┌────────┐ ─────────────────────────────────────────────▶ ┌──────────┐
   │  NONE  │                                                │ MINTING  │ POST /v1/live-sessions
   └────────┘ ◀──────── sign out · app backgrounded ──────── └────┬─────┘ (user-scoped, new)
       ▲                                                          │ token (use within 60 s)
       │ failure: back off, retry later (no user-facing error)    ▼
       │                                                    ┌──────────┐
       └─────────────────────────────────────────────────── │CONNECTING│ socket + setup
                                                            └────┬─────┘
                                                                 │ setupComplete
                     goAway / 9-min timer (budget allows)        ▼
                  ┌───────────────────────────────────────── ┌─────────┐
                  │  refresh: mint + connect a replacement,  │  READY  │ blank, mic closed,
                  │  swap it in, close the old one           │ (blank) │ no notebook
                  └────────────────────────────────────────▶ └────┬────┘
                                                                  │ claim(notebookId)
                                                                  ▼
                                               handed to the notebook; immediately
                                               start MINTING a new blank standby
```

- **Budget:** the existing `WarmBudget` caps refreshes while the user is inactive, then goes cold until the next interaction, so an idle dashboard doesn't keep minting tokens indefinitely.
- **Background:** iOS suspends sockets anyway, so the standby closes when the app is backgrounded and is rebuilt on resume. This matches `journal_screen.dart` today, moved to app level.
- **If the standby isn't ready when claimed:** `claim()` waits for the in-flight connection, or starts one. That's the cold path, about 1–1.7 s, with no 5 s player wait.

### Flow 2: opening a notebook

```
                                  open notebook
                                        │
                     ┌──────────────────┴──────────────────┐
             new (no turns yet)                    has turns (old notebook)
                     │                                     │
                     ▼                                     ▼
   ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
   │ LOADING page: "Lumen is joining…" │   │ load graph + previous transcript │
   │ claim standby                     │   │ status: IDLE (not live)          │
   │ greeting starts                   │   │ graph and transcript views both  │
   └────────────────┬─────────────────┘   │ work; nothing auto-starts         │
                    │ connected + greeting └────────────────┬─────────────────┘
                    │ playing                               │ tap mic
                    ▼                                       ▼
   ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
   │ page reveals; LIVE                │   │ RESUMING: claim standby →        │
   │ mic opens after the greeting      │   │ send context (recent transcript) │
   └──────────────────────────────────┘   │ → no greeting → LIVE, mic open   │
                                          └──────────────────────────────────┘
   If connecting fails or passes 10 s: page reveals with an error banner and a
   Retry button (decision D3).
```

"New" means the notebook has no finalized turns: locally, and on the server
once D1 lands. It isn't based on `ended_at`.

### Flow 3: the notebook session state machine

```
            ┌───────────────── open old notebook ─────────────────┐
            ▼                                                     │
      ┌──────────┐   tap mic    ┌───────────┐  claimed +   ┌──────┴────┐
      │   IDLE   │ ───────────▶ │ RESUMING  │  context ──▶ │   LIVE    │◀── new notebook,
      │ viewing  │              │ claim,    │  sent        │ mic open  │    greeting done
      │ graph +  │ ◀─ fails ─── │ send      │              │ streaming │
      │ history  │  (error      │ context   │              └──┬─────┬──┘
      └──────────┘   banner)    └───────────┘        tap mic  │     │ tap End ■
            ▲                                                 ▼     │
            │                                          ┌───────────┐│
            │                                          │  PAUSED   ││
            │                           tap mic ──────▶│ mic closed││
            │                           (resume:       │ connection││
            │                           instant) ◀─────│ kept      ││
            │                                          └─────┬─────┘│
            │                              tap End ■         │      │
            │                                                ▼      ▼
            │                                          ┌──────────────────┐
            └────────────────────────────────────────── │ ENDING           │
                    (notebook stays open,               │ close connection │
                     graph + transcript stay)           │ finish turns     │
                                                        └──────────────────┘

   Connection lost while PAUSED (goAway / 30-min limit / network):
     PAUSED ──▶ reconnect in the background: claim a new blank standby, re-send the
                context, stay PAUSED. The user sees nothing; the next tap is instant.
   Connection lost while LIVE: the same reconnect, shown as a brief "Reconnecting".
   Leaving the notebook screen from any state: ENDING, then the screen pops.
```

- **Pause** stops mic capture and sends Gemini `audioStreamEnd`, so it closes off the user's utterance instead of waiting for more.
- **End** no longer makes the notebook un-resumable. It ends the voice session; the notebook can be continued later from its screen. `ended_at` becomes a "last session ended" timestamp only (decision D5).
- **Notebooks are created only by the dashboard's New notebook action.** `startSession`'s fallback to `ensureActiveNotebook()`, which inserts silently, is removed.

### Flow 4: context hand-off on resume

A standby connection is blank and its system instruction is generic, so the
notebook context is sent right after the claim, before the mic opens:

1. The **recent transcript**: the last turns, capped by size (about 20 turns or
   ~2,000 tokens), sent as prior conversation history (`clientContent` turns
   with user/model roles). This doesn't prompt a reply.
2. A **resume note**: "This notebook continues an earlier conversation. Don't
   greet; wait for the user."
3. The **graph** stays on demand through the existing `get_graph_summary` and
   `get_relevant_memory` tools, which already read the open notebook.

To verify during implementation: the current Live API's handling of seeded
history, i.e. that history sent with the turn left open doesn't trigger a
reply. The fallback is a single context message plus the resume note.

## Work plan

### Phase 0: runtime route (`infra/`, needs a deploy by the owner)

- `POST /v1/live-sessions`: user-scoped, reuses the existing authorizer and
  token constraints. There's no notebook check, because the token isn't tied
  to a notebook.
- Keep `POST /v1/notebooks/{id}/live-sessions` for the web client.
- Tests alongside the existing lambda tests. Deploy with `cdk deploy`
  (requires AWS credentials, which this machine doesn't have).
- Until it's deployed, the client can fall back to the notebook route when a
  notebook is open, so Phases 1–3 can be built and tested without waiting.

### Phase 1: app-level services (client)

- `VoiceStandby` provider: Flow 1, a small state machine unit-tested with a
  fake runtime and a fake socket.
- `AudioOutput` provider: one `PcmPlayer` for the signed-in user, initialised
  at sign-in with a timeout, reused by every session, disposed at sign-out.
- Wire both to auth state (`auth_provider.dart`) and app lifecycle.

### Phase 2: notebook session machine (client)

- `JournalNotifier`: IDLE / RESUMING / LIVE / PAUSED / ENDING (Flow 3);
  `pauseMic()` / `resumeMic()`; claims from `VoiceStandby` instead of preparing
  its own connection; context hand-off (Flow 4); background reconnect while
  paused.
- Remove the per-notebook warm-up and the silent notebook insert.
- `GeminiLiveClient`: `sendAudioStreamEnd()`, `sendHistory(turns)`.
- Dock: a "Paused" chip state; the mic ring only while LIVE.

### Phase 3: opening notebooks (client)

- New notebook: a loading page until LIVE with the greeting playing, then the
  reveal (Flow 2); a timeout plus error banner with Retry.
- Old notebook: opens IDLE with the graph and transcript; no auto-start.
- The dashboard's New notebook action is the only place notebooks are created.

### Phase 4: transcript persistence across devices (optional, decision D1)

- Supabase table `conversation_turns` (notebook, turn id, speaker, text,
  spoken-at), written when a turn is finalized, read when a notebook opens.
  Local checkpoints stay as the offline cache.

### Tests per phase

| Phase | Tests |
| --- | --- |
| 0 | user-scoped route: 401 without auth, token constraints unchanged, no notebook lookup |
| 1 | standby: sign-in warms; claim hands out and re-warms; refresh on goAway swaps without a gap; budget stops refreshing; background and sign-out close it; failures back off silently |
| 1 | audio output: initialised once; a stalled `init()` never blocks a session (regression for today's hang) |
| 2 | mic toggles LIVE ⇄ PAUSED without reconnecting; End → IDLE with the notebook still open; resume sends context and no greeting; reconnect while paused stays paused; nothing inserts a notebook |
| 3 | new notebook: loader until LIVE, then greeting; old notebook: IDLE with graph + transcript, no session; timeout shows Retry |

## Decisions for the owner

| # | Question | Default if unanswered |
| --- | --- | --- |
| D1 | Should old transcripts sync across devices (Phase 4), or is on-device only enough for now? | On-device now; Phase 4 later |
| D2 | On resume, should Lumen stay silent until spoken to, or say a short "welcome back" line? | Silent |
| D3 | If Lumen can't connect when a new notebook opens: Retry only, or also "open without voice"? | Both |
| D4 | How long should the sign-in standby stay warm while the user is inactive? | Existing budget (a few refreshes), then cold until the next interaction |
| D5 | Does End finish a notebook for good, or only end the voice session (notebook resumable)? | Voice session only |
| D6 | Can you run `cdk deploy` for Phase 0, or should Phases 1–3 ship first on the notebook-route fallback? | Build 1–3 on the fallback; deploy Phase 0 when you can |

## Expected result

| Moment | Today | After |
| --- | --- | --- |
| Tap mic in an open notebook | 1–1.7 s cold, plus 5 s player wait on the simulator | Instant when the standby is ready; ~1–1.7 s if not |
| Open a new notebook | Page shows at once, session starts behind it | Brief "Lumen is joining…", then the page with the greeting playing |
| Open an old notebook | Graph only; tapping the mic starts a fresh session and a new notebook | Graph and previous transcript; tapping the mic continues with context |
| Tap mic mid-session | Ends the notebook and reconnects from scratch into a new notebook | Pauses; tapping again resumes instantly |

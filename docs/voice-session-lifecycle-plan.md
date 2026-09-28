# Voice session lifecycle: plan

Date: 2026-09-27 (revised after market research). Branch:
`feat/voice-session-lifecycle`, off `main` at `4d9843f`.

## Status

| Phase | State |
| --- | --- |
| 0 | Done and deployed (`ca-central-1`); `POST /v1/live-sessions` live |
| 1 | Done: `LiveCredentials`, `AudioOutput`, `VoiceServicesScope` |
| 2 | Done: resumption, compression, voice detection, pre-connect buffer, pause/resume, context seeding, echo cancellation, dock states; warm standby removed |
| 3 | Not started |

Until Phase 3, reopened notebooks have no local transcript (the device keeps
only turns still being saved), so Phase 2 seeds context from this run's turns
or, failing that, the notebook's saved journal entries.

## Goals

1. **Credentials once per sign-in, not per notebook.** The AWS credential
   exchange happens in the background as soon as the user is signed in, and is
   refreshed quietly, so opening a notebook or tapping the mic never waits on it.
2. **A new notebook opens with Lumen.** The first time a notebook opens,
   Lumen's greeting plays automatically. The page shows a loading state until
   Lumen is connected.
3. **An old notebook opens quietly.** No session starts on its own. The user
   sees the existing graph and the previous transcript. Tapping the mic picks
   up where the conversation left off: no greeting, and Lumen has the earlier
   context.
4. **The mic pauses and resumes.** Tapping the mic mid-session pauses it and
   tapping again resumes. Only the End button ends the session. No action
   ever creates a notebook the user didn't ask for.
5. **Sessions don't die on their own.** Conversations can run past Gemini's
   15-minute audio limit, and dropped connections come back with their
   context.

## What the research changed

The first draft kept a blank Gemini connection open from sign-in. Comparing it
with Gemini Live, OpenAI Realtime, LiveKit Agents, Hume EVI, ElevenLabs Agents
and ChatGPT Voice changed four things:

| Finding | Source | Change |
| --- | --- | --- |
| Other products pre-fetch the credential, not a connection. Setup takes only 0.3–0.4 s once a token is in hand (our logs) | ElevenLabs signed URLs (15-min start window), OpenAI client secrets (reusable until expiry) | Hold a **token** from sign-in; connect on demand. No standing connection, refresh loop or hand-off |
| The 60-second start window is our own setting (`newSessionExpireTime` in `core.mjs`), Gemini's default rather than a limit | Gemini ephemeral-token docs | The user-scoped route issues tokens with a longer start window (default 10 min, configurable) |
| LiveKit records from the tap and sends the buffered audio once connected | LiveKit pre-connect audio buffer | **Pre-connect buffer**: nothing said during connection is lost |
| Gemini audio sessions end at 15 min unless context window compression is on. Session resumption restores a session with full context for 2 h, reusing the same token within its 30-min life even with `uses: 1` | Gemini session-management and ephemeral-token docs | Enable **`contextWindowCompression`** and **`sessionResumption`**; reconnect with resumption handles instead of re-sending context |

What the research confirmed:

- **Mic pause/resume.** Matches ChatGPT Voice's mute, via Gemini's `audioStreamEnd`.
- **Seeding history for old notebooks.** Gemini's documented `clientContent` turns with `turn_complete=False`; OpenAI apps do the same. Keep the system prompt constant, because Hume warns that changing it on resume causes odd behaviour.
- **The bundled greeting covering the connection time.** Keep it.
- **Transcripts stored on the server.** Hume and ChatGPT do this, which is what makes history available on any device.
- **Explicit voice detection and on-device echo cancellation.** Gemini recommends 500–800 ms of silence before a turn ends. ElevenLabs moved to WebRTC largely for its echo cancellation.

## Constraints in the current code

| Fact | Where | Consequence |
| --- | --- | --- |
| Tokens are minted per notebook route, `uses: 1`, 60 s start window, 30 min life, limited to the model and audio output | `infra/lambda/live-session/core.mjs` | Phase 0 adds a user-scoped route with a configurable start window |
| The token isn't tied to a notebook; the route only checks the notebook exists and is the user's | same | Dropping the notebook check is safe: the authorizer already proves the user |
| The setup message sends no `sessionResumption`, `contextWindowCompression` or voice-detection settings | `lib/services/gemini_live_client.dart` | Phase 2 adds them |
| Audio frames captured before setup completes are dropped | `gemini_live_client.dart` (`dropped N early mic frames`) | Phase 2 buffers them instead |
| The audio player's `init()` can stall on the simulator, and `dispose()` waits behind it; the session waits 5 s for it | `pcm_player.dart`, `journal_provider.dart` | Phase 1 moves the player to app level, initialised once |
| The mic button calls `endSession()` = `leaveNotebook()` (sets `ended_at`); the next start silently inserts a notebook | `journal_screen.dart`, `journal_provider.dart:1477`, `supabase_service.dart:23` | Phase 2: pause/resume; notebooks created only from the dashboard |
| Both speakers' turns are saved only on the device (`TurnJournalService`); Supabase keeps graph and entries | `turn_journal_service.dart`, migrations | Phase 3 adds server-side transcripts |
| Mic capture has no gain, echo cancellation or noise suppression | `lib/audio/pcm_capture.dart` | Phase 2 turns them on |

## Architecture

```
 ┌──────────────────────── App level (lives for the signed-in user) ────────────────────────┐
 │  LiveCredentials                                   AudioOutput                           │
 │  · fetches a user-scoped token at sign-in          · one PcmPlayer, initialised at       │
 │  · refreshes it before its start window lapses       sign-in, reused by every session    │
 │    (HTTP only, no connection)                      · plays the bundled greeting          │
 │  · take() hands out a valid token, then re-fetches                                       │
 └───────────────────────────────┬──────────────────────────────────────────────────────────┘
                                 │ take() → token (connect within its window)
 ┌───────────────────────────────▼──────────────────────────────────────────────────────────┐
 │  Notebook level (JournalNotifier, one open notebook)                                     │
 │  · loads graph + previous transcript                                                     │
 │  · connects on demand (~0.35 s) with resumption + compression + tuned voice detection    │
 │  · pre-connect buffer: records from the tap, flushes when live                           │
 │  · seeds recent transcript for old notebooks; resumes with handles after drops           │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flows

### Flow 1: credentials (from sign-in)

```
            sign in · app resumed · token window about to lapse
   ┌──────┐ ─────────────────────────────────────────▶ ┌──────────┐
   │ NONE │                                            │ FETCHING │ POST /v1/live-sessions
   └──────┘ ◀───────── sign out ────────────────────── └────┬─────┘ (user-scoped)
       ▲                                                    │
       │ failure: back off and retry; no user-facing error  ▼
       │                                              ┌──────────┐  take() ──▶ token to caller,
       └───────────────────────────────────────────── │   HELD   │            then FETCHING again
                                                      └──────────┘
   Refresh while HELD: re-fetch shortly before the start window ends (e.g. at 8 of 10 min).
   Stop refreshing after a period of inactivity; fetch on the next interaction.
```

### Flow 2: opening a notebook

```
                                  open notebook
                     ┌──────────────────┴──────────────────┐
             new (no turns yet)                    has turns (old notebook)
                     ▼                                     ▼
   ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
   │ LOADING: "Lumen is joining…"      │   │ IDLE: graph + previous transcript│
   │ take token → connect (~0.35 s)    │   │ nothing auto-starts              │
   │ greeting starts                   │   └────────────────┬─────────────────┘
   └────────────────┬─────────────────┘                    │ tap mic
                    ▼                                       ▼
   ┌──────────────────────────────────┐   ┌──────────────────────────────────┐
   │ page reveals · LIVE               │   │ RESUMING: record at once (buffer)│
   │ mic opens after the greeting      │   │ take token → connect → seed      │
   └──────────────────────────────────┘   │ recent transcript → flush buffer │
                                          │ → LIVE (no greeting)             │
   Timeout (10 s) or failure: page        └──────────────────────────────────┘
   reveals with an error banner, Retry and "open without voice".
```

"New" means the notebook has no finalized turns, not anything based on `ended_at`.

### Flow 3: the notebook session state machine

```
      ┌──────────┐   tap mic    ┌───────────┐   connected,   ┌───────────┐◀── new notebook,
      │   IDLE   │ ───────────▶ │ RESUMING  │ ─ context ───▶ │   LIVE    │    greeting done
      │ viewing  │ ◀─ fails ─── │ (buffering│   seeded       │ mic open  │
      │ graph +  │  (banner)    │  the mic) │                └──┬─────┬──┘
      │ history  │              └───────────┘        tap mic    │     │ tap End ■
      └──────────┘                                  ┌───────────▼┐    │
            ▲                                       │   PAUSED   │    │
            │                           tap mic ───▶│ mic closed │    │
            │                           (instant)◀──│ + stream   │    │
            │                                       │ end sent   │    │
            │                                       └─────┬──────┘    │
            │                               tap End ■     ▼           ▼
            │                                       ┌──────────────────────┐
            └────────────────────────────────────── │ ENDING: close, finish│
                  notebook stays open and resumable │ pending turns        │
                                                    └──────────────────────┘

   goAway / network drop / a pause past the connection's ~10-min life:
     reconnect with the latest resumption handle (same token within 30 min,
     otherwise a fresh token from LiveCredentials). Context stays on Google's
     side for 2 h. The state doesn't change; LIVE shows a brief "Reconnecting".
   Beyond 2 h or after End: the next tap seeds context again (RESUMING).
```

### Flow 4: context for old notebooks

On RESUMING, after setup completes and before the buffered audio is flushed:

1. **Recent transcript:** the last turns, capped by size (about 20 turns or
   ~2,000 tokens), sent as `clientContent` turns with user/model roles and
   `turn_complete=false`, which doesn't prompt a reply.
2. **Resume note:** "This continues an earlier conversation in this notebook.
   Don't greet; wait for the user."
3. **The graph** stays on demand through `get_graph_summary` and
   `get_relevant_memory`.

The system instruction never changes between sessions.

## Work plan

### Phase 0: user-scoped live-session route (`infra/`)

- `POST /v1/live-sessions`: same authorizer, same token constraints (model and
  audio output, `uses: 1`, 30 min life), no notebook lookup.
- Start window configurable (`LIVE_SESSION_START_WINDOW_SECONDS`, default 600,
  clamped to 60–1800 s and to the token's life). The notebook route keeps its
  60 s window so the web client is unchanged.
- Response includes `newSessionExpiresAt` so clients can refresh before it lapses.
- Tests next to the existing lambda tests, plus a CDK assertion for the new
  route. Update `infra/README.md`.
- Deploy with `cdk deploy`, which needs AWS credentials. Until deployed, the
  client falls back to the notebook route when a notebook is open.

### Phase 1: app-level services (client)

- `LiveCredentials`: Flow 1, unit-tested with a fake runtime and clock.
- `AudioOutput`: one `PcmPlayer` for the signed-in user, initialised at sign-in
  with a timeout, reused by every session, disposed at sign-out. A stalled
  `init()` can never block a session.
- Wired to auth state and app lifecycle.

### Phase 2: sessions (client)

- `GeminiLiveClient`: `sessionResumption` (store `newHandle`; reconnect with
  it), `contextWindowCompression`, `realtimeInputConfig` voice detection
  (silence ≈700 ms), `sendAudioStreamEnd()`, `sendHistory(turns)`, and
  buffering instead of dropping pre-setup audio.
- `JournalNotifier`: IDLE / RESUMING / LIVE / PAUSED / ENDING (Flow 3),
  `pauseMic()` / `resumeMic()`, reconnect by handle, context seeding (Flow 4).
  Remove the per-notebook warm standby and the silent notebook insert.
- `pcm_capture.dart`: automatic gain, echo cancellation and noise suppression
  where the platform supports them.
- Dock: "Paused" and "Reconnecting" chip states.

### Phase 3: opening notebooks + server-side transcripts

- New notebook: loader until LIVE with the greeting playing; timeout banner
  with Retry and "open without voice".
- Old notebook: opens IDLE with graph and transcript; no auto-start.
- Supabase `conversation_turns` table (notebook, turn id, speaker, text,
  spoken-at) with owner-only RLS, written at finalization and read on open.
  Local checkpoints stay as the offline cache.

### Tests per phase

| Phase | Tests |
| --- | --- |
| 0 | user-scoped route: 401 without auth; no notebook lookup; start window default, clamping and config; constraints unchanged; notebook route unchanged; CDK route exists |
| 1 | credentials fetched at sign-in, refreshed before lapsing, re-fetched after take(), stop when inactive, cleared at sign-out, silent back-off; player initialised once and never blocks a session |
| 2 | setup includes resumption/compression/voice detection; goAway reconnects by handle with no new token inside 30 min; pre-setup audio is buffered and flushed in order; LIVE ⇄ PAUSED without reconnecting; resume seeds context and no greeting; nothing inserts a notebook |
| 3 | new notebook loader and greeting; old notebook IDLE with graph + transcript; timeout banner; turns round-trip through `conversation_turns` |

## Decisions

Defaults, to be confirmed by the owner:

| # | Question | Default |
| --- | --- | --- |
| D1 | Server-side transcripts (Phase 3)? | Yes |
| D2 | On resume, silent or a short "welcome back"? | Silent |
| D3 | If Lumen can't connect when a new notebook opens? | Retry and "open without voice" |
| D4 | Token start window | 10 minutes, refreshed in the background |
| D5 | Does End finish a notebook for good? | No, it ends the voice session; the notebook stays resumable |
| D6 | Deploy order | Phase 0 deployed by the owner; client phases work on the fallback until then |

## Expected result

| Moment | Today | After |
| --- | --- | --- |
| Tap mic in an open notebook | 1–1.7 s cold, plus a 5 s player wait on the simulator | Recording starts on the tap; live in ~0.35 s |
| Open a new notebook | Page shows at once; the session starts behind it | Brief "Lumen is joining…", then the page with the greeting playing |
| Open an old notebook | Graph only; the mic starts a fresh session in a new notebook | Graph and previous transcript; the mic continues with context |
| Tap mic mid-session | Ends the notebook, reconnects from scratch into a new notebook | Pauses; tapping again resumes instantly |
| A conversation past 15 minutes | Gemini ends the session | Continues (compression); drops reconnect with context |

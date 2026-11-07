# Session brief v1

What Lumen says first in a returning user's next conversation, written when the
previous one ends. One brief per user; the most recent close wins. The route
below writes it, `get_session_brief()` reads it, and `mark_session_brief_played`
retires it. Opening copy rules live in `infra/lambda/close-session/brief-prompts.mjs`.

## Write: `POST /v1/notebooks/{notebookId}/brief`

Authenticated like `/close` (the Supabase bearer token; the same authorizer).
The app calls it in parallel with `/close` when a notebook is left. It is
best-effort: if it fails, the previous brief stays and nothing else is
affected.

Two request shapes coexist. A body with no `version` (or no body) is
**request v1**, described in this section: the runtime reads the transcript
and the memory lists from the database, writes the brief, speaks it and saves
both. A body with `"version": 2` is **request v2** (LM-56), described under
"Request v2" below: the app sends the text, names swapped, and saves the
result itself. The stored brief and `get_session_brief` are the same for both.

Only `just_talk` notebooks produce a brief.

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"status":"ready"}` | A new brief and its audio were saved. |
| 200 | `{"status":"unchanged"}` | Nothing to do: see "Repeated and late calls". No model or speech call was made. |
| 400 | `{"status":"rejected","code":"invalidRequest"}` | The notebook id is not a UUID. |
| 401 | `{"status":"rejected","code":"unauthorized"}` | Missing or invalid token. |
| 404 | `{"status":"rejected","code":"notFound"}` | The notebook is not the caller's. |
| 422 | `{"status":"rejected","code":"nothingToSummarize"}` | The user said nothing in this notebook. |
| 429 | `{"status":"rejected","code":"rateLimited"}` | The provider is rate limiting. Retry later. |
| 501 | `{"status":"rejected","code":"notImplemented"}` | The notebook is not `just_talk`. |
| 502 | `{"status":"rejected","code":"invalidProviderResponse"}` | The model returned no usable brief, or speech returned no audio. Nothing was saved. |
| 503 | `{"status":"rejected","code":"providerUnavailable"}` | A provider or Supabase call failed, or the deadline was near. |

### Repeated and late calls

Close can run more than once for one notebook. The route returns
`unchanged` when the stored brief:

- came from this notebook at a revision at or after the notebook's current one; or
- came from a different notebook and was created after this notebook ended
  (a delayed retry for an older session must never overwrite a newer brief).

Otherwise the stored brief is replaced, and its `played_at` is cleared.

### What goes into the brief

The model sees this conversation's transcript, the previous brief (so open
threads carry forward), unanswered follow-ups, open questions on entities, and
the most-mentioned entities across all notebooks. One forced
`write_session_brief` call writes the brief; Gemini TTS then speaks
`openingLine`.

## Request v2 (LM-56): names swapped on the device

So that no real name reaches the text model, v2 splits the write in two. Old
apps keep sending v1; the runtime answers both.

### 1. Write the text

```json
{
  "version": 2,
  "turns": [{ "speaker": "user", "text": "Anika is moving to Corvale.", "spokenAt": "2026-10-23T21:00:10Z" }],
  "previous": { "focus": ["…"], "openingThread": "…" },
  "followUps": ["…"],
  "questions": [{ "name": "Anika", "questions": ["…"] }],
  "topEntities": [{ "name": "Anika", "type": "person" }],
  "sourceRevision": 7
}
```

Every string has the user's known names replaced by stand-ins on the device
(the name map, LM-55). `turns` is the conversation, oldest first; `previous`
is the stored brief (or `null`); `followUps`, `questions` and `topEntities` are
what v1 reads from `follow_ups`, `entities` and `user_entities`. The runtime
reads none of those from the database, still runs `redact_forgotten_text` over
all of it (a forgotten name has left the map), and reads `notebooks` and
`session_briefs` for ownership and the "Repeated and late calls" rules.
`sourceRevision` (optional) is the notebook revision the app read before the
transcript; the brief is for the lower of it and the notebook's.

| Field | Limit |
|---|---|
| `turns` | 1 to 1000; `speaker` `user` or `assistant`; `text` 1 to 20 000 characters; 100 000 characters in all; `spokenAt` optional ISO time |
| `previous.focus` | at most 10 strings of at most 500 characters |
| `previous.openingThread` | at most 1000 characters |
| `followUps` | at most 10 strings of at most 1000 characters |
| `questions` | at most 10; `name` at most 200 characters; 1 to 20 `questions` of at most 500 |
| `topEntities` | at most 15; `name` at most 200 characters; `type` an entity type |

A body outside these is a 400 `invalidRequest`, before any other call.

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"status":"ready","brief":{…},"sourceRevision":7}` | The brief text, not saved, with stand-ins in it. No speech call was made. |
| 200 | `{"status":"unchanged"}` | As v1. |

Other statuses as v1.

### 2. Speak the opening line

The app swaps the real names back into the brief, then sends the opening line
alone:

```json
{ "version": 2, "speak": { "openingLine": "Hey, how is Priya's move going?", "sourceRevision": 7 } }
```

`openingLine` 1 to 160 characters; `sourceRevision` the one step 1 returned.
The runtime checks the notebook is the caller's, runs the "Repeated and late
calls" rules again for that revision (a newer brief saved meanwhile is not
replaced), and sends only `openingLine` to Gemini TTS. This one sentence is
the only text with real names that goes to Google on this route.

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"status":"ready","audioBase64":"…","sampleRate":24000}` | The audio, not saved. |
| 200 | `{"status":"unchanged"}` | Nothing to speak or save. |
| 400 | `invalidRequest` | Malformed body, or `sourceRevision` ahead of the notebook. |

### 3. Save

The app saves through `save_session_brief(p_notebook_id, p_source_revision,
p_brief, p_audio_base64, p_sample_rate)` with the user's token, exactly as the
runtime does on v1. Every check stays in that function: the caps, a revision
that is not newer for the same notebook is not saved, and a brief naming a
forgotten person is not saved (`unchanged`).

## Stored brief

`brief` is JSON with exactly these fields:

| Field | Type | Limit |
|---|---|---|
| `focus` | string[] | 1 to 4 items, each at most 140 characters |
| `openingThread` | string | 0 to 200 characters; empty when the line asks nothing specific |
| `openingLine` | string | 1 to 160 characters |

The server trims whitespace and clamps over-long text before saving (an
over-long line ends with "…"). An empty or missing `openingLine`, or no
non-empty `focus` item, is a 502 and nothing is saved. An empty `openingThread`
is valid: when no thread is safe to raise (a painful topic the person didn't
ask to follow up on), the line is a warm greeting with no specific question and
the thread is left empty, rather than the model inventing one. `focus` still
needs at least one line: a 422 already covers a notebook where nothing was
said, so there is always something to note as context. The save function independently rejects an empty or over-160 line, or
empty audio, with Postgres `22023`.

## Opening audio

PCM16, mono, **24000 Hz** (`sampleRate` is read from the TTS response's mime
type and defaults to 24000). Voice `Aoede`, model `gemini-2.5-flash-preview-tts`,
the same voice as the bundled intro clip. It travels base64-encoded in the
save and is stored as `bytea`, one clip per user.

## Read: `get_session_brief()`

Called with the user's token. Returns:

```json
{
  "returning": true,
  "brief": {
    "sourceNotebookId": "8e03b8f4-4f20-4df3-8398-d854adc32b14",
    "createdAt": "2026-10-23T21:05:00.000Z",
    "playedAt": null,
    "focus": ["The Atlas demo on Thursday"],
    "openingThread": "They said the Atlas demo is on Thursday.",
    "openingLine": "Hey, good to hear from you. Did the Atlas demo go the way you hoped?",
    "audioBase64": "…",
    "sampleRate": 24000
  }
}
```

`brief` is `null` when none exists. `returning` is true when the account has
any notebook with `entity_count > 0`, any `conversation_turns` row with
`speaker = 'user'`, or any `session_cards` row.

## When a brief is usable

The app plays a brief's audio only when **all** of these hold:

- `playedAt` is null: **one play per brief**. `mark_session_brief_played(created_at)`
  sets it for the row with that exact `createdAt`, so another device sees it too;
- the brief is **under 21 days old** (21 days exactly is unusable);
- the audio is not empty.

Otherwise a returning user hears the bundled fallback clip, never the intro.
An unknown state at tap time also means the fallback, except for an account
created in this app run.

## Changes

Fields may be added. Removing or renaming one, or changing a limit, needs v2.

- 2026-10-29 (before first deploy): `openingThread` may be empty. Readers
  already treated a missing thread as `""`.
- 2026-11-07 (LM-56): request v2 (write text, speak, save in the app). The
  stored brief, the read and request v1 are unchanged. Deploy the runtime
  before releasing an app that sends v2.

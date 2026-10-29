# Session brief v1

What Lumen says first in a returning user's next conversation, written when the
previous one ends. One brief per user; the most recent close wins. The route
below writes it, `get_session_brief()` reads it, and `mark_session_brief_played`
retires it. Opening copy rules live in `infra/lambda/close-session/brief-prompts.mjs`.

## Write: `POST /v1/notebooks/{notebookId}/brief`

Authenticated like `/close` (the Supabase bearer token; the same authorizer).
No request body. The app calls it in parallel with `/close` when a notebook is
left. It is best-effort: if it fails, the previous brief stays and nothing else
is affected.

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

## Stored brief

`brief` is JSON with exactly these fields:

| Field | Type | Limit |
|---|---|---|
| `focus` | string[] | 1 to 4 items, each at most 140 characters |
| `openingThread` | string | at most 200 characters |
| `openingLine` | string | 1 to 160 characters |

The server trims whitespace and clamps over-long text before saving (an
over-long line ends with "…"). A missing or empty field is a 502 and nothing is
saved. The save function independently rejects an empty or over-160 line, or
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

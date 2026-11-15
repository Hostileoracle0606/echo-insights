# Close session: request v2

`POST /v1/notebooks/{notebookId}/close` writes the closing card (LM-15) and,
with `"draft": true`, a draft of it while the conversation goes on. The card
it returns and `session_cards.card` store are `session-card-v1.schema.json`.

Two request shapes coexist. Old apps keep working; deploy the runtime before
releasing an app that sends v2.

## Request v1 (no `version`)

Body `{}` (final close) or `{"draft": true}`; no body or one that isn't JSON
is a final close. The runtime reads the transcript from `conversation_turns`,
writes the card and saves it with `save_session_card`. A final close retries
once if the notebook moved on mid-write.

| Status | Body |
|---|---|
| 200 | `{"status":"ready","card":{…}}`, the saved card |
| 401 / 404 / 422 / 429 / 501 / 502 / 503 | `{"status":"rejected","code":…}` |
| 409 | `stale` (a final close that stayed stale after its retry) |

## Request v2 (LM-56)

So that no real name reaches the text model, the app sends the transcript
with every name it knows replaced by a stand-in (the device's name map,
LM-55), and the card comes back unsaved.

```json
{
  "version": 2,
  "draft": false,
  "turns": [{ "speaker": "user", "text": "Anika is moving to Corvale." }],
  "entities": [{ "key": "3b1f…(64 hex)", "name": "Anika" }],
  "sourceRevision": 7
}
```

- `turns`: the conversation, oldest first. 1 to 1000; `speaker` `user` or
  `assistant`; `text` 1 to 25 000 characters; 125 000 characters in all.
  The v2 caps are about 1.25 times the database's (`conversation_turns` is
  20 000): a stand-in can be longer than the name it replaced, so the app's
  text may grow a little, and the app clamps to these numbers. The model reads the last 24 000 characters, as
  in v1. The runtime does not read `conversation_turns`.
- `entities`: the stand-in name for the notebook's entities the card may
  remember; at most 500, `name` at most 250 characters. An entity is named
  by `key`, `sha256("<notebookId>:<entityId>")` in lowercase hex, never by
  its id: an id is the real name's slug. The runtime hashes the notebook's
  candidate ids the same way to match them. It is a namespaced hash, not a
  secret: someone who already suspects a name can hash a guess to confirm it. The model is offered each remember candidate as a short alias
  (`e1`, `e2`, …) and this name, never the id (an id is the real name's
  slug). A candidate with no entry here is left out of the prompt and is
  remembered without a note.
- `sourceRevision` (optional): the notebook revision the app read before the
  transcript. The card's `sourceRevision` is the lower of it and the
  notebook's, so a turn saved after the app read the transcript is never
  counted as covered.
- `draft`: as v1.

A turn the app could not swap safely (its round trip failed, or the name map
would not settle) is sent as `[omitted]`, and a candidate whose name could not
be swapped is left out. A conversation whose user turns are all `[omitted]`
(or empty) is a 422 `nothingToSummarize`: no card is written from it. A body
outside these limits, or a `version` other
than 2, is a 400
`invalidRequest` before any other call.

The runtime still checks the caller's token and reads, as that user:
`notebooks` (ownership, mode, revision, auto-forget), `session_cards` (a
current card is returned as is), `get_notebook_snapshot` and `user_entities`
(the remember list, its names and order). It runs `redact_forgotten_text`
over the app's turns and names (a forgotten name has left the map).

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"status":"ready","card":{…},"saved":false}` | A new card, not saved. Its title, summary, notes and remember notes carry stand-ins; `remember[].name` comes from the database. |
| 200 | `{"status":"ready","card":{…},"saved":true}` | The stored card is current (or the transcript was auto-forgotten): nothing to save. |

Other statuses as v1, except that v2 is never `stale`: nothing is saved here.

### Saving (the app)

The app puts the real names back into the model's text, using the stand-ins
as they were when it swapped the request, not the name map as it is when
the answer arrives. If the answer uses a stand-in that has since been
retired, moved to someone else or whose person was forgotten, the card is
dropped unsaved and asked for once more. Otherwise the app saves with
`save_session_card(p_notebook_id, p_source_revision, p_card, p_title,
p_summary, p_draft)` using the user's token, as the runtime does on v1. Every
rule stays in that function: a final card must match the notebook's revision
(`stale` otherwise; the app asks once more, as v1 did), a draft may not be
ahead of the notebook and never replaces a newer card, the caps, and
forgotten names are redacted from the stored card.

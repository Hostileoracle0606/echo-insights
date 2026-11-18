# Observation sheet

Print one per session and fill it in by hand. Afterwards, copy it into
the JSON below (one field per row, same names) and record it with
`record.mjs` (see README). Then destroy the paper.

**Never write** the person's name, anything they said to the app, or
anything about their life. Free-text boxes take 140 characters at most.

| Field | Fill in | Allowed values |
|---|---|---|
| `participant` | ______ | `P1` … `P9`, in the order people take part |
| `date` | ______ | date of the session, `YYYY-MM-DD` |
| `device` | ______ | `simulator` or `testflight` |
| `consent` | ☐ | must be `true` (they said yes to `consent.md`) |
| `secondsToFirstTurn` | ______ s | whole seconds from the end of the Task 1 prompt to the app's first reply; `null` if none within 8 min |
| `firstTurnMode` | ☐ voice ☐ typed | `voice`, `typed`, or `null` when there was no reply |
| `tasks.talk` | ☐ yes ☐ with help ☐ no | `yes`, `with_help`, `no` |
| `tasks.find` | ☐ yes ☐ with help ☐ no | `yes`, `with_help`, `no` |
| `tasks.correct` | ☐ yes ☐ with help ☐ no | `yes`, `with_help`, `no` |
| `listeningStateWhenAsked` | ☐ listening ☐ not listening | `listening` or `not_listening`: what the app was really doing when you asked question A |
| `comprehension.listening` | ☐ correct ☐ partial ☐ wrong | question A |
| `comprehension.purpose` | ☐ correct ☐ partial ☐ wrong | question B |
| `comprehension.keeps` | ☐ correct ☐ partial ☐ wrong | question C |
| `confusions` | one line each, below | `task` + `code` (+ `note`) |
| `quotes` | on the quotes paper | `text` + `approved` |
| `notes` | ______ | optional; behaviour only, 140 characters |

## Confusions

One line per moment. Codes from `confusion-codes.md`. `note` is optional,
except for `other`, where it is required.

| `task` (setup / talk / checks / find / correct) | `code` | `note` (≤ 140 characters) |
|---|---|---|
| | | |
| | | |
| | | |
| | | |
| | | |
| | | |

## JSON to record

Save this outside the repository (for example `~/first-use/P1.json`),
fill it in from the paper, and record it. Fields not listed here are
rejected.

```json
{
  "participant": "P1",
  "date": "2026-11-20",
  "device": "simulator",
  "consent": true,
  "secondsToFirstTurn": 42,
  "firstTurnMode": "voice",
  "tasks": { "talk": "yes", "find": "with_help", "correct": "no" },
  "listeningStateWhenAsked": "not_listening",
  "comprehension": { "listening": "correct", "purpose": "partial", "keeps": "wrong" },
  "confusions": [
    { "task": "talk", "code": "mic_state" },
    { "task": "find", "code": "other", "note": "looked for a search box" }
  ],
  "quotes": [
    { "text": "EXAMPLE - replace with the exact approved words", "approved": true }
  ],
  "notes": ""
}
```

Leave `quotes` as `[]` if there are none. A quote without
`"approved": true` is never shown in the summary; do not record quotes
the person said no to at all.

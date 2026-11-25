# Recovery — hand-run sheet

What scripts can't do: a real iPhone killed by a person, a real radio turned
off, and a person talking over Lumen. Three runs of each. Fill one table row
per run, then:

```bash
node eval/recovery/record-manual.mjs
```

which checks every row and writes `eval/results/<date>-<sha>/recovery-manual.json`.
Leave a row blank if it wasn't run; it is reported as pending, never guessed.

## Before you start

- A **test account** with nothing personal in it. Say only the scripted lines
  below; nothing you say here may be real.
- A physical iPhone with the build under test. Note its model for the
  `device` column (e.g. `iPhone 15`). No serials or names.
- After each run, look in the app (transcript and notebook) **and** count rows:
  `journal_entries` for the notebook, any line in twice is a duplicate.
  Duplicates go in the `duplicates` column as a count.

## Outcomes

For `physical_kill` and `airplane_mode` (the turn that was cut off is "turn 2"):

| outcome | meaning |
|---|---|
| `recovered` | turn 2 is in the notebook exactly once |
| `marked` | turn 2's words are in the transcript but not in the notebook |
| `dropped` | turn 2 is nowhere, and nothing else is missing |
| `duplicated` | anything appears twice |
| `lost_completed` | turn 1 (finished before the fault) is missing |

For `interrupt_reply`:

| outcome | meaning |
|---|---|
| `heard_only` | Lumen's reply in the transcript stops where you cut it off |
| `unheard_saved` | the transcript holds words of the reply you never heard |
| `reply_lost` | the part you did hear is missing too |

A pass is `recovered`, `marked` or `dropped` with 0 duplicates, or
`heard_only`. The `note` column is optional, at most 140 characters, and
describes what you did, not what you said.

## Cases

**physical_kill.** Start a session. Say turn 1: "Started the Lantern Bay
garden plot with Odette this morning." Wait until it shows in the notebook.
Say turn 2: "Odette introduced me to Imre, who keeps bees near the north
fence." As soon as you stop speaking, swipe the app away in the app switcher.
Reopen it and the notebook; wait 30 s.

**airplane_mode.** As above, but turn Airplane Mode on as soon as you stop
speaking turn 2. Wait 10 s, turn it off, wait 30 s in the app.

**interrupt_reply.** Ask "What do you know about the garden?" While Lumen is
mid-sentence, start talking ("Wait, one more thing"). Check the transcript.

## Sheet

| case | run | date | device | outcome | duplicates | note |
|---|---|---|---|---|---|---|
| physical_kill | 1 |  |  |  |  |  |
| physical_kill | 2 |  |  |  |  |  |
| physical_kill | 3 |  |  |  |  |  |
| airplane_mode | 1 |  |  |  |  |  |
| airplane_mode | 2 |  |  |  |  |  |
| airplane_mode | 3 |  |  |  |  |  |
| interrupt_reply | 1 |  |  |  |  |  |
| interrupt_reply | 2 |  |  |  |  |  |
| interrupt_reply | 3 |  |  |  |  |  |

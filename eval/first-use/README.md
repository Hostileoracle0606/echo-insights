# First-use study

Watches 3 to 5 people who have never used Lumen try it with no
explanation, and counts what happened: how long until the app first
replied, whether they finished three tasks, where they got confused, and
whether they could say what Lumen is for, when it is listening, and what
it keeps.

Nothing a participant says is kept. The repository holds only coded
observations (`P1`…`P9`, fixed codes, counts) and quotes about the app
that the person approved word for word.

| File | What it is |
|---|---|
| `protocol.md` | Facilitator script: exact wording, timings, help ladder, scoring rubrics |
| `consent.md` | Read aloud before starting |
| `observation-sheet.md` | Printable sheet, plus the JSON you record from it |
| `confusion-codes.md` | The fixed list of confusion codes |
| `seed.mjs` | Creates and wipes the study account on local Supabase |
| `record.mjs` | Checks one session's JSON and saves it under `eval/results/` |
| `summarize.mjs` | Counts across all recorded sessions → `first-use.json` |

## Privacy rules (the scripts enforce the starred ones)

- \* Participants are `P1` to `P9`. Names are rejected.
- \* Only the fields on the sheet are accepted. Anything else, and any
  field named like `transcript` or `content`, is rejected.
- \* Every piece of text is 140 characters or fewer.
- \* Only quotes the person approved word for word are recorded
  (`"approved": true`); the recorder rejects any other quote.
- \* The summary gives counts ("2 of 4"), never percentages.
- \* The study account is wiped after every person, and the wipe is
  checked by counting what is left (it must be 0).
- No audio or video recording. Paper notes are destroyed once recorded.
- What participants say goes to Google's Gemini service, which may hold on
  to it under Google's terms; `consent.md` tells them so. Erasing the
  study account clears only the Supabase side.
- Known bias: consent has to say the test account is erased afterwards,
  which hints that the app holds on to things before question C is asked.
- The JSON you fill in lives outside the repository until it is recorded.
- Never use your own account, or anyone's real account, for a session.

## Once, before the pilot

1. Start local Supabase (`supabase start` in the repo). Do not run
   `supabase db reset` while other eval work is using the stack.
2. Build the app against it. As in the main README's Quick start, but
   with the local values from `supabase status`:

   ```dotenv
   SUPABASE_URL=http://127.0.0.1:55321
   SUPABASE_PUBLISHABLE_KEY=<ANON_KEY from supabase status>
   NOTEBOOK_RUNTIME_URL=<runtime that accepts this stack's sessions>
   ```

   ```bash
   flutter run --dart-define-from-file=.env.study
   ```

   Name the file `.env.study` (it matches the `.env.*` ignore rule).
3. **Check the whole loop works before anyone sees it.** Seed the account
   (below), sign in, have one short spoken conversation, and confirm the
   app shows what it kept. Voice and memory extraction go through
   `NOTEBOOK_RUNTIME_URL`; if no runtime accepts local Supabase sessions,
   the study cannot run on the local stack. In that case choose a staging
   project, and change `assertLocal` in `seed.mjs` on purpose, in its own
   commit, to allow that one named host. Never the live project.
4. Check scoring rubrics B and C in `protocol.md` against what this build
   really keeps, and note any change in the change log below.

## Run a session

In a terminal at the repository root:

```bash
source eval/privacy/local-env.sh
```

**Before the person arrives**, wipe and reseed the study account:

```bash
node eval/first-use/seed.mjs --reset
```

The last line must say `remaining rows for first-use-study@example.test: 0`
(it exits 1 otherwise; do not run a session until it does).

```bash
node eval/first-use/seed.mjs
```

This creates `first-use-study@example.test` with one empty notebook and
prints a new password for this local test account. To reuse your own,
set `FIRST_USE_PASSWORD` in the shell first (never commit it).

Give the app a fresh microphone permission. On a simulator:

```bash
xcrun simctl privacy booted reset microphone com.echoinsights.lumen
```

On a TestFlight device, delete and reinstall the app. Then sign in to the
study account and leave the app on its first screen.

**With the person:** follow `protocol.md` from the top. Fill in the paper
sheet as you go.

**After they leave:**

1. Sign out of the app on the device.
2. Wipe the account and check it reports 0:

   ```bash
   node eval/first-use/seed.mjs --reset
   ```

3. Copy the paper sheet into a JSON file **outside the repository**, using
   the template in `observation-sheet.md` (for example
   `~/first-use/P1.json`), then record it:

   ```bash
   node eval/first-use/record.mjs ~/first-use/P1.json
   ```

   It prints what is wrong if the sheet breaks a rule; fix and rerun. On
   success it writes `eval/results/<date>-<commit>/first-use/P1.json`.
   A participant code can be recorded only once.
4. Delete the JSON file outside the repository and destroy the paper sheet.

If someone stops part way and asks for their notes to be thrown away,
record nothing and do not reuse their code.

## The pilot

Run the protocol once with someone friendly first. Do **not** record the
pilot. Change only the wording of the protocol (not the fields, codes or
rubric categories) and log each change below with the reason, before the
first real session.

## After all sessions

```bash
node eval/first-use/summarize.mjs
```

It reads every `eval/results/*/first-use/P*.json`, checks each again, and
writes `eval/results/<date>-<commit>/first-use.json`: median and range of
time to first reply, completion counts per task (`skipped` counted
separately, never as a failure), confusion counts per code, comprehension counts per question, and approved quotes. Commit the
per-person files and the summary together.

## Tests

```bash
node --test eval/first-use/*.test.mjs
```

## Protocol change log

| Date | Change | Why |
|---|---|---|
| | | |

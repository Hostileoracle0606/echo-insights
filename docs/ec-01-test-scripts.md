# EC-01 test scripts — rebuild at a pause

Scripts to run by hand, typed or spoken, against a build with the rebuild
flag on. Each one says what to say, where the rebuild should land, and what
to check. Run them with `CONTEXT_REBUILD_MAX_TURNS=3`, so the rebuild comes
after Lumen's third reply, unless the script says otherwise.

## Setup

```bash
chmod +x scripts/ec01-rebuild-test.sh
```

Runs use the `lumen-staging` Supabase project by default, never
production. Start the notebook runtime against staging in its own terminal
and leave it running. It reads the Gemini key from `echo-insights/.env`, and
refuses production:

```bash
scripts/ec01-rebuild-test.sh runtime
```

Simulator (typed turns; the Mac's microphone also works for spoken turns,
but picks up room noise):

```bash
scripts/ec01-rebuild-test.sh sim 3
```

`EC01_ENV=dev` builds against production instead. A physical device can't
reach `127.0.0.1` on the Mac, so for device runs, set `NOTEBOOK_RUNTIME_URL`
in `.env.staging` to the Mac's LAN address.

Device (spoken turns; find the id with `flutter devices`):

```bash
scripts/ec01-rebuild-test.sh device <device-id> 3
```

After a run, stop the log and print the timing table:

```bash
scripts/ec01-rebuild-test.sh summary test-runs/<log file>
```

Use a fresh notebook for each script so earlier facts don't answer for the
session. Delete the test notebooks afterwards.

**Log markers to watch**

| Line | Means |
|---|---|
| `[rebuild] start reason=turnBudget turns=3 age=…` | Rebuild began at a pause |
| `[rebuild] seeded in …ms` | New session ready with saved context |
| `[rebuild] did not complete` | Rebuild failed; note what was happening |
| `[rebuild] first reply after rebuild is playing` | Lumen's first audio on the new session |
| `[latency] spoken turn → reply audio +…ms` | Reply latency for that turn |

**Pass for every script:** no "Reconnecting" chip, no greeting after the
rebuild, no mic cut-off, and the first reply after the rebuild is within the
range of the normal replies in the same run.

---

## S1 — A fact said before the rebuild

The baseline continuity check.

1. "My monthly savings goal is three hundred and fifty dollars now."
2. "My friend Maya starts her new job on Monday."
3. "I'm reading Dune this week."
   *Rebuild should start about 1 s after Lumen finishes this reply.*
4. "Remind me, what did I say my savings goal is?"
5. "It's mostly for a trip next summer."

**Check:** turn 4 answers $350. Turn 5 connects the trip to the savings goal.

## S2 — A value that changed (duplication)

Saved context holds both the old and the new value. Lumen must use the newer one.

1. "My savings goal was two hundred a month."
2. "Actually I raised it to three fifty last week."
3. "Work has been busy, nothing exciting."
   *Rebuild.*
4. "What's my savings goal right now?"
5. "And what was it before?"

**Check:** turn 4 says 350, not 200 and not both. Turn 5 says 200.

## S3 — A question left open across the rebuild

The rebuilt session has to carry on a thread Lumen started.

1. "I've been thinking about changing teams at work."
2. "There's a team doing voice products that looks interesting."
3. "Ask me something that would help me decide."
   *Lumen asks a question. Rebuild at the pause after it.*
4. Answer the question directly, without repeating it, for example: "Probably
   the people, honestly."

**Check:** Lumen treats turn 4 as the answer to its own question. It does not
ask what you mean, and it does not ask the same question again.

## S4 — Talking into the gap (barge-in)

The rebuild must wait while someone has the floor.

1. "Tell me a quick fact about octopuses."
2. "Another one."
3. "One more."
   *As Lumen's third reply ends, start talking immediately and keep going for
   5–10 seconds:* "Okay, so the reason I'm asking is that my niece loves
   octopuses and I want to get her something for her birthday."

**Check:** in the log, `start` comes only after you stop and Lumen has
replied, never while you are speaking. Your sentence is heard in full; no
words are lost at the switch.

## S5 — A long pause after the rebuild

The new session must not time out or go silent.

1. to 3. Any three short turns.
   *Rebuild.*
4. Stay silent for 30 seconds.
5. "Sorry, I'm back. Where were we?"

**Check:** Lumen sums up the last topic in a sentence and does not greet
again. No error state, no "Reconnecting".

## S6 — Several rebuilds in one session

Repeated rebuilds should not add up to drift. Use
`CONTEXT_REBUILD_MAX_TURNS=2` for more rebuilds per minute. The policy waits
at least 2 minutes between turn-budget rebuilds, so keep talking for about
7 minutes.

Talk about one topic throughout, for example planning a weekend trip. Every
few turns, refer back to something from the start: "What was the first place
I mentioned?"

**Check:** 3 or more rebuilds, each `seeded in` under ~600 ms on Wi-Fi.
Early details are still right after the last rebuild. Lumen does not
re-introduce the topic or repeat an earlier suggestion as new.

## S7 — Off the record never rebuilds

1. Go off the record.
2. Say 5 short turns.

**Check:** no `[rebuild]` lines at all. Coming back on the record reconnects
as before (an existing path, not part of EC-01).

## S8 — Memory tool on the first turn after the rebuild

1. "Today was the first day at my new gym."
2. "The trainer's name is Priya."
3. "My legs are already sore."
   *Rebuild.*
4. Ask about something from an earlier session, so Lumen has to use the
   memory tool: "What did I tell you about my sister last time?"

**Check:** the tool call works on the new session. Compare this turn's latency
with other tool turns in the same run, not with plain turns.

## S9 — The age limit (optional, 10+ minutes)

Run with `CONTEXT_REBUILD_MAX_TURNS=100` so only the age limit applies. Keep a
conversation going for just over 10 minutes.

**Check:** a `start reason=maxAge` line soon after the 10-minute mark, at a
pause. The session never hits Gemini's own session limit.

---

## Listening check (spoken runs)

Record the screen with audio for S1, S3 and S6 on a device. Give the
recording to someone who doesn't know where the rebuilds happen. Ask them to
mark every moment where Lumen sounds like it lost the thread, restarted, or
paused unnaturally. Compare their marks with the `start` timestamps in the
log.

Fill in one row per run:

| Script | Where | Rebuilds | Seeded (ms) | First reply after rebuild (ms) | Normal median (ms) | Heard by listener? | Notes |
|---|---|---|---|---|---|---|---|
| S1 | | | | | | | |
| S2 | | | | | | | |
| S3 | | | | | | | |
| S4 | | | | | | | |
| S5 | | | | | | | |
| S6 | | | | | | | |
| S7 | | | | | | | |
| S8 | | | | | | | |
| S9 | | | | | | | |

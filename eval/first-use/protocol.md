# First-use study: facilitator script

What this measures: whether someone who has never used Lumen can work out
what it is for, when it is listening, and what it keeps, with no
explanation. Three tasks, three questions, about 35 minutes.

Read every line in **bold** word for word. Everything else is for you.

## Ground rules for you

- **Do not explain the app.** Before the three questions (after Task 1),
  do not say any of these words or point at anything that means them:
  *listening, listen, microphone, mic, recording, memory, remember, keep,
  kept, save, saved, notes, graph*. If they ask "is it listening?" or
  "will it remember this?", answer: **"What do you think?"** and log the
  confusion.
- **Do not react** to what they say to the app. Do not write it down.
- **Do not lead.** If they ask you what to do, use the help ladder below,
  in order, and nothing else.
- **Code, do not judge.** Fill in the sheet (`observation-sheet.md`) as
  you go. Confusions use only the codes in `confusion-codes.md`.

## Help ladder (all tasks)

Wait until they have been stuck for **30 seconds** (no progress, or they
say they are stuck) before the first step. Then move one step at a time,
waiting 30 seconds between steps.

| Step | Say or do | Counts as help? |
|---|---|---|
| 1 | **"What are you looking for?"** | No |
| 2 | **"What would you try next?"** | No |
| 3 | Point at the area of the screen that would get them unstuck and say only **"Have a look here."** Do not name it or say what it does. | Yes: task is `with_help` |
| 4 | **"Let's move on."** Go to the next task. | Task is `no` |

If they reach the task's time limit, say **"Let's move on."** and mark the
task `no` unless they finished.

## Before they arrive (10 minutes)

1. Reset and reseed the study account (README, "Run a session").
2. Give the app a fresh microphone permission (delete and reinstall it, or
   on a simulator run the reset command in the README), so the system
   prompt appears as it would for a new user.
3. Open the app, sign in to the study account yourself, and leave it on
   the first screen after sign-in. Signing in is not part of the study.
4. Have a timer, the sheet, and a blank piece of paper for quotes.

## 1. Welcome and consent (3 minutes)

Read `consent.md` aloud. Continue only if they say yes.

**"This is an app called Lumen. I'm not going to explain it, because part
of what I'm testing is what it's like to use with no explanation. Please
think out loud as you go: say what you're looking at, what you expect,
and anything that surprises you. There are no wrong answers."**

Hand them the device.

## 2. Task 1: talk through your day (up to 8 minutes)

**"Use the app to talk through your day so far. It can be real or made
up. Keep going until you've said what you want to say, or until about
five minutes have passed."**

- Start the timer when you finish reading the task.
- **Time to first successful turn:** stop watching the clock the first
  time the app replies to something the person said or typed (a spoken
  reply or a reply on screen). Write the seconds in
  `secondsToFirstTurn`, and whether they spoke or typed in
  `firstTurnMode`. If it never happens within 8 minutes, leave both as
  `null`.
- Done (`yes`): they had at least one back-and-forth with the app and
  stopped on their own.
- At 8 minutes: **"Let's stop there."**

## 3. The three questions (5 minutes)

Ask these **straight after Task 1, before they touch anything else**, in
this order. Ask each question exactly once. You may add **"Anything
else?"** once per question, and nothing more. Do not say whether an answer
is right.

Before asking question A, look at the screen and note whether the app is
actually listening at that moment: `listening` or `not_listening` in
`listeningStateWhenAsked`.

**A. "Right now, is the app listening to you?"** then **"How can you
tell?"** (field `listening`)

- `correct`: their answer matches the actual state, and they point to
  something real on screen or something the app did.
- `partial`: their answer matches, but they cannot say how they know, or
  say they are guessing.
- `wrong`: their answer does not match the actual state, or they cannot
  say.

**B. "In your own words, what is this app for?"** (field `purpose`)

- `correct`: both halves: a place to talk through your day or what is on
  your mind, **and** it remembers the people, projects or feelings you
  mention from one time to the next.
- `partial`: only one half (for example "a voice diary", or "it remembers
  things about me").
- `wrong`: something else (for example a general assistant for questions
  or tasks, a voice recorder, a therapist), or "don't know".

**C. "When you finish with the app today, what do you think it will keep
from what you just did?"** (field `keeps`)

- `correct`: it keeps the people, projects or feelings it picked out of
  what they said, and these carry into later conversations.
- `partial`: it keeps "something" or "a log" but cannot say what, or names
  only part of the above.
- `wrong`: nothing; everything; or a confident wrong answer (for example
  "only what I tell it to save").

The owner checks rubrics B and C against the build during the pilot and
records any change in the README's change log.

## 4. Task 2: find what it kept (up to 5 minutes)

From here on you may use the words in the ground rules.

**"Find what the app kept from what you just told it."**

- Done (`yes`): they reach a screen showing something from Task 1 and say
  that is it.
- If they say it kept nothing, ask **"Where would you look to check?"**
  once, then let them carry on.

## 5. Task 3: correct one thing (up to 5 minutes)

**"Look at what it kept. Pick one thing it got wrong and fix it. If
everything looks right, pick any one thing and change it as if it were
wrong."**

- Done (`yes`): the change shows in the app (edited, removed, or put
  right by telling it). You confirm it on screen.
- Any way of making the change counts. Note in `notes` which way they
  chose only if it is unusual.

## 6. Wrap up (5 minutes)

**"That's everything. Was there anything that surprised you, or anything
you expected it to do that it didn't?"**

Listen; do not write down anything they say about their own life.

**Quotes.** During the session, jot on the blank paper any remark **about
the app** that you might want to use (140 characters or fewer). Now read
each one back exactly:

**"I'd like to use this sentence, word for word, without your name: '…'.
Is that OK?"**

Only a clear yes makes it `"approved": true`. Changed wording must be read
back again. If they say no, cross it out.

**"Thank you. Everything you said to the app is deleted when I reset the
account, which I'll do now."**

## 7. After they leave (5 minutes)

1. Sign out of the app on the device.
2. Reset the study account and check it reports 0 rows (README).
3. Copy the paper sheet into the JSON sheet and record it (README).
4. Destroy the paper sheet and the quotes paper.

## Timings

| Part | Time limit |
|---|---|
| Welcome and consent | 3 min |
| Task 1: talk | 8 min |
| Three questions | 5 min |
| Task 2: find | 5 min |
| Task 3: correct | 5 min |
| Wrap up and quotes | 5 min |
| **Total with the person** | **about 31 min, at most 40** |

# Contextual session opening — tickets

Lumen introduces itself once. After that, every new notebook opens like a friend catching up: a recorded greeting and one question about something left open, in Lumen's voice, with no wait. The greeting comes from a **session brief** written when the previous session ends.

- **Spec:** `docs/superpowers/specs/2026-10-28-contextual-session-opening-design.md`
- **Plan, with the exact signatures and tests:** `docs/superpowers/plans/2026-10-28-contextual-session-opening.md`
- **Branch:** `feat/contextual-opening`, stacked on PR #21.

| Ticket | Title | Area | Size | Depends on |
|---|---|---|---|---|
| LM-37 | `session_briefs` table and RPCs | Supabase | S | — |
| LM-38 | Brief route: write the next opening at session close | Lambda + CDK | M | LM-37 |
| LM-39 | Returning-user fallback clip | Flutter assets | S | — |
| LM-40 | Load the brief at sign-in and choose the opening | Flutter | M | LM-37 |
| LM-41 | Play the chosen opening and tell Gemini what was said | Flutter | M | LM-38, LM-39, LM-40 |
| LM-42 | Deploy and verify on the simulator | Release | S | all |

LM-37 and LM-39 can start in parallel today. LM-38 and LM-40 can run in parallel once LM-37's RPC shapes are fixed.

**Rules every ticket follows:**
- **Opening start:** starting a notebook never waits, and no Gemini connection is held open.
- **Closing card:** its code path and latency don't change.
- **Writes** go only through SECURITY DEFINER RPCs called with the user's token. No service key.
- **Opener copy:**
  - a warm hello plus **one** question;
  - no recap, no "I'm Lumen", no "I remember";
  - painful topics only if the user framed them as something to follow up on;
  - no dates that go stale.
- **Never commit** `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.

---

## LM-37: `session_briefs` table and RPCs

**Area:** Supabase · **Size:** S · **Depends on:** —

One row per user holds the current brief and its opening audio. The app reads it, marks it played, and learns whether the account is returning.

### Scope
- **Table** `session_briefs`: `user_id` (pk, cascades from `auth.users`), `source_notebook_id`, `source_revision`, `brief jsonb {focus[], openingThread, openingLine}`, `audio bytea`, `sample_rate`, `created_at`, `played_at`. Owner-only select, with no direct writes.
- **`save_session_brief(notebook, revision, brief, audio_base64, sample_rate)`:**
  - returns `unchanged` for the same notebook at a revision `>=` the stored one;
  - replaces the row otherwise and clears `played_at`;
  - rejects an empty or overlong (>160) `openingLine` and empty audio with `22023`.
- **`get_session_brief()`** returns `{returning, brief | null}`. `returning` is true when the account has any notebook with `entity_count > 0`, any user turn, or any card.
- **`mark_session_brief_played(created_at)`** marks only the row with that exact `created_at`.

### Files
- `supabase/migrations/20261029000000_session_briefs.sql`
- `supabase/tests/database/session_briefs_test.sql`

### Done when
- `supabase test db` passes and covers:
  - other users and `anon` can't access the table or the functions;
  - direct writes fail;
  - saving twice returns `unchanged`;
  - played-marking works, including from another device;
  - `returning` is true for an entities-only account;
  - deleting the account removes the brief.

---

## LM-38: Brief route — write the next opening at session close

**Area:** Lambda + CDK · **Size:** M · **Depends on:** LM-37

When a notebook is left, the app calls `POST /v1/notebooks/{id}/brief` in parallel with `/close`. One model call writes the brief and the opening line, and Gemini TTS records the line in Lumen's voice (`Aoede`, 24 kHz PCM16).

### Scope
- **New Lambda** `SessionBriefFunction` from the `close-session` directory (`brief-index.handler`, 30 s), with its own route on the existing API and authorizer.
- **Shared code:** the Supabase client, the rejection helpers and the Gemini call are exported from `core.mjs`. Close behaviour is unchanged.
- **Inputs** to the model:
  - this session's transcript;
  - the previous brief (open threads carry forward);
  - unanswered follow-ups;
  - entity questions;
  - the top entities across all notebooks.
- **Responses:**
  - no model call when the brief for this revision already exists;
  - `422` with no user turns, `501` for non–Just talk notebooks;
  - an empty line or missing audio saves nothing (`502`), so the previous brief stays.
- **Logs:** ids, counts and latency only.
- **Contract doc:** `contracts/session-brief-v1.md`.

### Files
- `infra/lambda/close-session/{brief.mjs, brief-prompts.mjs, brief-index.mjs, core.mjs}`
- `infra/lib/infra-stack.ts`
- `infra/test/{session-brief.test.mjs, infra.test.ts}`
- `contracts/session-brief-v1.md`

### Done when
- `cd infra && npm test` passes, including the existing close-session tests unchanged.
- The tests cover the happy path, idempotency, 422/501/502, prompt rules, the TTS voice and model, and that no text appears in logs.

---

## LM-39: Returning-user fallback clip

**Area:** Flutter assets · **Size:** S · **Depends on:** —

A second recorded clip for returning users when no brief is usable: "Hey, good to see you again. What's on your mind today?" It keeps the start instant and never reintroduces Lumen.

### Scope
- `tool/generate_opening_audio.mjs` takes an asset name. Generate `lumen_returning.wav` in the same voice. The key is read from `.env`, never passed on the command line.
- `StandardOpening.loadReturning()` sits next to `load()`.

### Files
- `assets/audio/lumen_returning.{txt,wav}`
- `tool/generate_opening_audio.mjs`
- `lib/audio/standard_opening.dart`
- `test/standard_opening_test.dart`

### Done when
- The clip loads at 24 kHz with audio, and its text doesn't say "I'm Lumen".

---

## LM-40: Load the brief at sign-in and choose the opening

**Area:** Flutter · **Size:** M · **Depends on:** LM-37

The app has the brief in memory before you tap New notebook, and decides which clip to play without waiting.

### Scope
- **`SessionBrief` model** and **`SessionBriefService`**: `requestBrief`, `load`, `markPlayed`.
- **`OpeningPrep`:**
  - refreshes at sign-in, alongside the existing token, player and turn-journal warm-up, and when the app returns to the foreground;
  - never throws;
  - the sign-up screen marks a brand-new account.
- **`chooseOpening(state, knownNewAccount, now)`** picks one of:
  - **intro** for a known-new account, or one that isn't returning;
  - **brief** when one is usable: not yet played and under 21 days old;
  - **fallback** otherwise, *including when the state is still unknown*.

### Files
- `lib/models/session_brief.dart`, `lib/services/session_brief_service.dart`, `lib/logic/opening_choice.dart`, `lib/providers/opening_prep_provider.dart`
- `lib/providers/voice_services_provider.dart`, `lib/screens/auth/signup_screen.dart`
- Tests: `opening_choice_test.dart`, `session_brief_service_test.dart`, `voice_services_binding_test.dart`

### Done when
- Choice tests pass for: new, unknown, not returning, usable, played, exactly 21 days, empty audio.
- The brief decodes correctly.
- Sign-in and resume both refresh it.

---

## LM-41: Play the chosen opening and tell Gemini what was said

**Area:** Flutter · **Size:** M · **Depends on:** LM-38, LM-39, LM-40

This connects the pieces in the journal.

### Scope
- **A new notebook** plays the clip `chooseOpening` picked: the intro, the brief's own audio, or the fallback. Playing a brief marks it played locally and on the server.
- **The up-front context** sent before Gemini's first reply becomes:
  - `[opening said] "<exact line>"`;
  - `[session brief] {focus, openingThread, alreadyRaised}`;
  - `[graph summary]`.
- **The `SESSION OPENING` prompt** points at `[opening said]` instead of hard-coding the intro. Lumen never greets twice, and follows up the brief's thread instead of asking it again.
- **Leaving a notebook** also fires `requestBrief` and then a refresh. A failure there never blocks leaving.
- **Continuing a notebook** is unchanged.

### Files
- `lib/providers/journal_provider.dart`, `lib/logic/conversation_policy.dart`
- Tests: `standard_opening_test.dart`, `journal_session_lifecycle_test.dart`, `journal_joining_test.dart`

### Done when
- `flutter analyze` is clean and the full suite passes.
- The tests show:
  - each opening's line reaches `[opening said]`;
  - `markPlayed` happens only for a brief;
  - a continuing notebook gets no opening;
  - leaving requests a brief and survives its failure.

---

## LM-42: Deploy and verify on the simulator

**Area:** Release · **Size:** S · **Depends on:** LM-37 to LM-41

### Scope
- **Ask for approval first.** Show:
  - `supabase db push --linked --dry-run`, which must list only `20261029000000`;
  - `cdk diff`, which must show additions only.
- **Then deploy.** Until PR #19 merges, `db push` needs `20260922000000_account_deletion.sql` present locally. The brief route returns `401` without auth.
- **Simulator checks:**
  1. Leave a notebook after a typed turn.
  2. Open a new one: Lumen asks about that topic, with the greeting starting as fast as today.
  3. Open another: the fallback plays, because the brief is used.
  4. Open one before the sign-in load finishes, or offline: the fallback plays, never the intro.
- **Open a PR** into PR #21's branch, or into `main` if #21 has merged.

### Done when
- All four simulator checks pass, and the PR lists what was verified.

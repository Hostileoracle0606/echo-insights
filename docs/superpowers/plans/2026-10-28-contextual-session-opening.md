# Contextual Session Opening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A returning user's new notebook opens instantly with a recorded, personal greeting and question in Lumen's voice. The greeting is written from a session brief that's prepared when the previous session ends. A first-time user still hears the intro.

**Architecture:**
- **Server:** when a notebook is left, the app calls a new runtime route, `POST /v1/notebooks/{id}/brief`, in parallel with `/close`, so the card never waits. The route runs on its own Lambda, built from the close-session code directory. It writes the brief with one model call and renders the opening line with Gemini TTS. It saves both through a SECURITY DEFINER RPC into one row per user, `session_briefs`.
- **App:** at sign-in it loads that row through `get_session_brief()`, which also says whether the account is returning. On a new notebook it picks intro, brief or fallback without waiting, and plays the chosen clip through the existing `StandardOpening` path. It then tells Gemini the exact line it played, plus the brief, in the up-front context block.

**Tech Stack:** Supabase Postgres + pgTAP, Node 20 ESM Lambda (`node:test`), AWS CDK (jest), Flutter/Riverpod (`flutter_test`).

**Spec:** `docs/superpowers/specs/2026-10-28-contextual-session-opening-design.md`

## Global Constraints

- **Worktree and branch:** `~/Developer/lumen-opening`, branch `feat/contextual-opening`, stacked on PR #21.
- **Opening audio:** PCM16 mono, 24 kHz. TTS model `gemini-2.5-flash-preview-tts`, voice `Aoede`, the same as `tool/generate_opening_audio.mjs`.
- **Brief model:** `gemini-2.5-flash`, function calling forced, `temperature: 0`, `thinkingBudget: 0` (as `core.mjs`).
- **Scope:** briefs come only from `just_talk` notebooks. Other modes return `501 notImplemented`.
- **When a brief is unusable:** once it's been played (`played_at` set), or when it's 21 days old or older. Either way, returning users hear the fallback clip.
- **Returning account:** any notebook with `entity_count > 0`, any `conversation_turns` row with `speaker = 'user'`, or any `session_cards` row. Unknown at tap means fallback, except an account signed up in this app run, which gets the intro.
- **Starting a session never waits** on the brief or the returning lookup. No Gemini connection is held open, and the credential prefetch is unchanged.
- **The closing card's code path, latency and responses don't change.** The brief route is separate.
- **Server writes** go only through SECURITY DEFINER functions granted to `authenticated` and called with the user's token. No service-role key, no new secret.
- **The first-time intro clip** (`assets/audio/lumen_opening.*`) is unchanged.
- **Opener copy rules (spec §3.2–3.3):**
  - shape: a warm hello plus **one** specific question, 1–2 sentences;
  - not allowed: a recap, a list, "I'm Lumen", or "I remember / according to my notes";
  - painful topics only if the user framed them as something to follow up on, and asked gently;
  - if no thread is safe, a warm greeting with no specific question;
  - no dates that go stale.
- **Never commit** `pubspec.lock`, `ios/Podfile.lock` or `docs/assets/*`. Run `git checkout -- docs/assets pubspec.lock ios/Podfile.lock` after Flutter runs.
- **Never deploy without explicit user approval** (Task 7). Live Supabase is `bjoevzvsdlhlcjywpyfx`. `db push` needs `20260922000000_account_deletion.sql` present locally until PR #19 merges (copy it from `chore/restore-account-deletion-migration`, then delete it again).

## Review Focus

1. **Close runs more than once for one notebook** (leave, then the card retries, then leave again). The brief route must not call the model twice or save twice for the same revision. Test: Task 2, "a stored brief at the notebook's revision returns without a model call".
2. **A brief that has already played, or is 21+ days old,** must never play again. Another device must see it as played too. Tests: Task 1, `played_at` is visible after `mark_session_brief_played`; Task 3, `chooseOpening` returns fallback for played or old briefs.
3. **An account with notebooks from before this ships but no cards or turns** (entities only) counts as returning. Test: Task 1, "entities-only account is returning".
4. **The model returns an empty or overlong opening line, or TTS returns no audio.** Nothing is saved, and the previous brief stays. Tests: Task 2, "an empty openingLine is an invalid provider response, nothing saved" and "TTS without audio saves nothing".
5. **The user taps New notebook before the sign-in load returns.** The fallback plays with no wait, and the intro never plays for a returning user. Test: Task 3, `chooseOpening(state: null, knownNewAccount: false)` returns fallback.

---

### Task 1: `session_briefs` table and RPCs

**Files:**
- Create: `supabase/migrations/20261029000000_session_briefs.sql`
- Test: `supabase/tests/database/session_briefs_test.sql` (fixtures pattern from `session_cards_test.sql`)

**Interfaces:**
- **Produces the table** `public.session_briefs`, with one row per user:
  - `user_id uuid pk references auth.users on delete cascade`
  - `source_notebook_id uuid references notebooks(id) on delete set null`
  - `source_revision bigint not null`
  - `brief jsonb not null`: `{focus: text[], openingThread: text, openingLine: text}`
  - `audio bytea not null`, `sample_rate int not null`
  - `created_at timestamptz not null default now()`, `played_at timestamptz`
  - RLS: owner select only. Revoke insert, update and delete from `authenticated`; revoke all from `anon`.
- **Produces** `save_session_brief(p_notebook_id uuid, p_source_revision bigint, p_brief jsonb, p_audio_base64 text, p_sample_rate int) returns jsonb`:
  - SECURITY DEFINER, granted to `authenticated`, with the `auth.uid()` and notebook-ownership checks of `save_session_card`.
  - Returns `{status:'saved'}`, `{status:'unchanged'}` when the row already has the same notebook and a revision `>=` the incoming one, or `{status:'rejected', code:'notFound'}`.
  - Raises `22023` when `openingLine` is empty or longer than 160 characters, or when the audio decodes to empty.
  - A save replaces the user's row, sets `created_at = now()`, and clears `played_at`.
- **Produces** `get_session_brief() returns jsonb`, security invoker, returning `{returning: bool, brief: null | {focus, openingThread, openingLine, sourceNotebookId, createdAt, playedAt, sampleRate, audioBase64}}`. `returning` follows the Global Constraints rule, for `auth.uid()`.
- **Produces** `mark_session_brief_played(p_created_at timestamptz) returns void`:
  - SECURITY DEFINER, granted to `authenticated`;
  - sets `played_at = now()` only where `user_id = auth.uid()`, `created_at = p_created_at` and `played_at is null`, so a newer brief is never marked by mistake.

- [ ] **Step 1: Write the failing pgTAP tests**
  - user A saves a brief; `get_session_brief()` as A returns its `openingLine`, `sampleRate` 24000 and non-empty `audioBase64`;
  - B sees `brief: null`;
  - `anon` is denied on the table and on all three functions;
  - a direct `insert`/`update` on `session_briefs` as `authenticated` throws `42501`;
  - saving the same notebook and revision twice returns `unchanged`;
  - a newer save replaces the row and clears `played_at`;
  - `mark_session_brief_played` with the row's `created_at` sets `playedAt`; with another timestamp it changes nothing;
  - empty `openingLine` throws `22023`;
  - `returning` is false for a fresh account and true for each of:
    - an entities-only account (`entity_count > 0`);
    - an account with a user turn;
    - an account with a card;
  - deleting the `auth.users` row removes the brief.
- [ ] **Step 2: Run and confirm they fail.** Run `supabase db reset --local && supabase test db --local`. Expected: `session_briefs_test.sql` fails because the relation doesn't exist.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run all database tests.** Same command. Expected: every file `ok`, `Result: PASS`.
- [ ] **Step 5: Commit** with `feat(db): session_briefs, one opening brief per user`.

### Task 2: Brief route in the close-session Lambda directory

**Files:**
- Create: `infra/lambda/close-session/brief.mjs` (handler factory), `infra/lambda/close-session/brief-prompts.mjs`, `infra/lambda/close-session/brief-index.mjs` (entry, mirrors `index.mjs`)
- Modify: `infra/lambda/close-session/core.mjs`. Export the existing `supabaseClient`, `Rejection`, `rejected`, `jsonResponse`, `authorizedUserId`, `bearerAuthorization`, `notebookIdFrom` and a `callGemini({fetchImpl, credential, model, body, startedAt, deadlineMs, now, sleep, metrics})` extracted from `callModel`, with behaviour unchanged.
- Modify: `infra/lib/infra-stack.ts`, `infra/test/infra.test.ts`
- Test: `infra/test/session-brief.test.mjs`

**Interfaces:**
- **Consumes:** `save_session_brief` and the `session_briefs` select from Task 1. `buildTranscript` comes from `validate.mjs`.
- **Produces** `createSessionBriefHandler({supabaseUrl, publishableKey, getPermanentCredential, fetchImpl, model, ttsModel, voice = "Aoede", now, sleep, log, deadlineMs}) => (event) => response`. It responds with:
  - `200 {status:'ready'}` after a save, or `{status:'unchanged'}`;
  - `422 nothingToSummarize` when there are no user turns;
  - `501 notImplemented` for non-`just_talk` notebooks;
  - `401`, `400`, `404`, `409`, `429`, `502` and `503` with the same codes and meanings as close.
- **Produces** `writeSessionBriefFunction`:
  - `{name:"write_session_brief", parameters:{focus: string[] (1–4 items, ≤140 chars each), openingThread: string (≤200), openingLine: string (≤160)}}`;
  - `briefFromModel(args)` returns the cleaned fields or `null` (uses `cleanText` from `validate.mjs`).
- **Steps:**
  1. Check ownership and mode with the same `notebooks` select as `closeOnce`.
  2. If the user's row already holds this notebook at a revision `>=` the current one, return `unchanged` with no model call.
  3. Load in parallel:
     - turns (as close does);
     - the previous brief: `session_briefs?select=brief,created_at`;
     - open follow-ups: `follow_ups?answered=eq.false&select=question&order=created_at.desc&limit=10`;
     - entities with questions: `entities?questions=not.is.null&select=name,questions&order=last_seen.desc&limit=10`;
     - top entities: `user_entities?select=name,type,mentions&order=mentions.desc&limit=15`.
  4. One forced `write_session_brief` call.
  5. TTS via `generateContent` with `responseModalities:["AUDIO"]` and the `prebuiltVoiceConfig` from `tool/generate_opening_audio.mjs`. Prompt prefix: `Say warmly, unhurried and natural, like a friend catching up: `. Read `inlineData`; the rate comes from the mimeType, default 24000.
  6. `save_session_brief`.
- **Logs** follow `core.mjs` rules: ids, counts and latency only, never text.

- [ ] **Step 1: Write the failing tests** with the `world()` fake-fetch pattern from `close-session.test.mjs`:
  - happy path: one model call and one TTS call, then a save whose `p_brief.openingLine` equals the model's and whose `p_sample_rate` is 24000;
  - every Supabase call carries the user's bearer token;
  - "a stored brief at the notebook's revision returns without a model call";
  - no user turns gives 422 and no model call;
  - `weekly_debrief` gives 501;
  - "an empty openingLine is an invalid provider response, nothing saved", as 502;
  - an overlong line is clamped to 160;
  - "TTS without audio saves nothing", as 502;
  - the model receives the previous brief's `openingThread`, the follow-up questions and the top entity names in its message;
  - the system instruction contains `briefPrompt`, which names "one question", "never", "I remember", "painful" and "follow up" (assert those substrings);
  - TTS request: model `gemini-2.5-flash-preview-tts`, voice `Aoede`;
  - log lines contain no transcript, brief or line text.
- [ ] **Step 2: Run and confirm they fail.** Run `cd infra && node --test test/session-brief.test.mjs`. Expected: failure on importing `brief.mjs`.
- [ ] **Step 3: Implement** `core.mjs` exports, `brief-prompts.mjs` (`briefPrompt` per Global Constraints copy rules, `writeSessionBriefFunction`, `buildBriefMessage({transcript, trimmed, previous, followUps, questions, topEntities})`), `brief.mjs`, and `brief-index.mjs`. The entry reads env `GEMINI_SECRET_ARN`, `GEMINI_BRIEF_MODEL` and `GEMINI_TTS_MODEL`.
- [ ] **Step 4: Add the CDK function and route.** Add `SessionBriefFunction` in `infra-stack.ts`:
  - built from the same `close-session` asset, handler `brief-index.handler`, timeout 30 s;
  - env `...sharedEnvironment`, `GEMINI_SECRET_ARN`, `GEMINI_BRIEF_MODEL: "gemini-2.5-flash"`, `GEMINI_TTS_MODEL: "gemini-2.5-flash-preview-tts"`;
  - `reserveConcurrency` and `grantRead`;
  - route `POST /v1/notebooks/{notebookId}/brief` on the same API and authorizer as `/close`.

  In `infra.test.ts`, extend the route test to expect the brief route, and add "runs the session brief writer with its brief and TTS models and a 30 s timeout".
- [ ] **Step 5: Run the infra tests.** Run `cd infra && npm test`. Expected: jest and `node --test` both pass, including the existing `close-session.test.mjs` unchanged.
- [ ] **Step 6: Commit** with `feat(runtime): session brief route writes the next opening and its audio`.

### Task 3: App brief service, opening choice and sign-in prep

**Files:**
- Create: `lib/models/session_brief.dart`, `lib/services/session_brief_service.dart`, `lib/logic/opening_choice.dart`, `lib/providers/opening_prep_provider.dart`
- Modify: `lib/providers/voice_services_provider.dart` (warm-up and resume), `lib/screens/auth/signup_screen.dart` (mark a new account)
- Test: `test/opening_choice_test.dart`, `test/session_brief_service_test.dart`, `test/voice_services_binding_test.dart` (extend)

**Interfaces:**
- **Consumes:** Task 1's `get_session_brief`, `mark_session_brief_played`; Task 2's route.
- **Produces** `class SessionBrief`:
  - fields: `List<String> focus`, `String openingThread`, `String openingLine`, `DateTime createdAt`, `DateTime? playedAt`, `Uint8List pcm`, `int sampleRate`;
  - `factory fromJson(Map)`, which decodes `audioBase64`;
  - `bool usableAt(DateTime now)`, true when `playedAt == null`, `now.difference(createdAt) < Duration(days: 21)` and `pcm` is non-empty.
- **Produces** `class SessionOpeningState { final bool returning; final SessionBrief? brief; }`.
- **Produces** `enum OpeningChoice { intro, brief, fallback }` and `OpeningChoice chooseOpening({required SessionOpeningState? state, required bool knownNewAccount, required DateTime now})`, applying the rule in Global Constraints.
- **Produces** `class SessionBriefService`, mirroring `SessionCardService`'s runtime auth and base URL:
  - `Future<void> requestBrief(String notebookId)`: POSTs `/v1/notebooks/{id}/brief` with body `{}`. Errors are thrown to the caller, which logs them.
  - `Future<SessionOpeningState> load()`: the `get_session_brief` RPC.
  - `Future<void> markPlayed(DateTime createdAt)`.
- **Produces** `sessionBriefServiceProvider` and `openingPrepProvider` (a `Provider<OpeningPrep>`). `OpeningPrep` has:
  - `SessionOpeningState? get current`;
  - `bool get knownNewAccount`;
  - `Future<void> refresh()`, which never throws and logs failures;
  - `void markNewAccount()`;
  - `void markPlayedLocally()`.
- **Changes** `VoiceServicesBinding.warmUp`, so the sign-in warm-up runs `turnJournal.warmUp()` and `openingPrep.refresh()` together. `AppLifecycleState.resumed` also calls `openingPrep.refresh()`. Add an `onResume` callback parameter to `VoiceServicesBinding`.

- [ ] **Step 1: Write the failing tests.**
  - `opening_choice_test.dart`, with `now = DateTime(2026, 10, 29, 9)`:
    - `knownNewAccount: true` returns intro, even with a brief present;
    - `state: null` returns fallback;
    - `returning: false` returns intro;
    - a usable brief returns brief;
    - `playedAt` set returns fallback;
    - created exactly 21 days ago returns fallback, and 20 days 23 h ago returns brief;
    - empty `pcm` returns fallback.
  - `session_brief_service_test.dart`:
    - `SessionBrief.fromJson` decodes base64 to the same bytes, and parses `createdAt` and `playedAt`;
    - `requestBrief` POSTs to `$base/v1/notebooks/nb-1/brief` with a bearer token (fake `http.Client`).
  - `voice_services_binding_test.dart`: sign-in calls `warmUp`; `resumed` calls `onResume`.
- [ ] **Step 2: Run and confirm they fail.** Run `flutter test test/opening_choice_test.dart test/session_brief_service_test.dart test/voice_services_binding_test.dart`. Expected: compile failures for the missing files and symbols.
- [ ] **Step 3: Implement** the model, choice function, service, providers and binding change. The sign-up screen calls `ref.read(openingPrepProvider).markNewAccount()` after `signUpWithEmail` succeeds.
- [ ] **Step 4: Run the tests.** Same command. Expected: all pass.
- [ ] **Step 5: Commit** with `feat(app): load the session brief at sign-in and choose the opening`.

### Task 4: Returning-user fallback clip

**Files:**
- Create: `assets/audio/lumen_returning.txt`, containing the line: `Hey, good to see you again. What's on your mind today?`
- Create: `assets/audio/lumen_returning.wav`, generated
- Modify: `tool/generate_opening_audio.mjs`, which takes an optional asset name argument (default `lumen_opening`)
- Modify: `lib/audio/standard_opening.dart`, adding `static Future<StandardOpening> loadReturning(AssetBundle bundle)` and constants `returningTextAsset` and `returningAudioAsset`. Share the loader with `load`.
- Modify: `pubspec.yaml` asset list, if the assets aren't covered by a directory entry
- Test: `test/standard_opening_test.dart` (extend)

- [ ] **Step 1: Write the failing test.** `loadReturning(rootBundle)` returns a 24000 Hz clip with non-empty PCM. Its text equals the `.txt` file and doesn't contain `I'm Lumen`.
- [ ] **Step 2: Run and confirm it fails.** Run `flutter test test/standard_opening_test.dart`. Expected: `loadReturning` isn't defined.
- [ ] **Step 3: Implement it and generate the audio.** Run `set -a; . ./.env; set +a; node tool/generate_opening_audio.mjs lumen_returning`. Expected: `Wrote …/lumen_returning.wav: ~3.xs at 24000Hz`. Never put the key on the command line.
- [ ] **Step 4: Run the test.** Same command. Expected: pass.
- [ ] **Step 5: Commit** with `feat(audio): bundled returning-user greeting`.

### Task 5: Play the chosen opening and tell Gemini what was said

**Files:**
- Modify: `lib/providers/journal_provider.dart`: `_loadStandardOpening` becomes `_loadOpening()`, plus `_startGreeting` (~1736), the up-front `sendHistory` context (~1640) and `_writeSessionCard` (~2085)
- Modify: `lib/logic/conversation_policy.dart`: the `SESSION OPENING` section and a new `openingContext` function
- Test: `test/standard_opening_test.dart` (the prompt-sync test changes), `test/journal_session_lifecycle_test.dart`, `test/journal_joining_test.dart` (extend)

**Interfaces:**
- **Consumes:** `chooseOpening`, `OpeningPrep`, `SessionBrief` and `SessionBriefService` from Task 3, and `StandardOpening.loadReturning` from Task 4.
- **Produces** `String openingContext({required String? openingLine, SessionBrief? brief, required bool briefAlreadyRaised, required Map<String, dynamic> graphSummary})`, which returns the newline-joined lines:
  - `[opening said] "<line>"`, only when `openingLine != null`;
  - `[session brief] {"focus":…,"openingThread":…,"alreadyRaised":bool}`, only when `brief != null`;
  - `[graph summary] <json>`.
- **Changes the `SESSION OPENING` prompt text:**
  - The app has already greeted the user in your voice, and the exact words are in `[opening said]`.
  - Never greet again, never repeat or paraphrase that line, and don't speak until the user does.
  - If `[session brief]` is present, its `openingThread` is what the greeting asked about. Follow it up naturally when the user answers, and don't ask it again.
  - The prompt no longer contains the literal intro text.

**Behaviour:**
- **A new notebook** (`!continuing`) picks the clip by `chooseOpening(state: prep.current, knownNewAccount: prep.knownNewAccount, now: DateTime.now())`:
  - `intro`: `StandardOpening.load`;
  - `brief`: `StandardOpening(text: brief.openingLine, pcm: brief.pcm, sampleRate: brief.sampleRate)`;
  - `fallback`: `loadReturning`.

  This is a synchronous choice over already-loaded state. Only the bundled asset load is awaited, as today.
- **When a brief clip actually plays** (`fed == true`): call `prep.markPlayedLocally()`, then `unawaited(service.markPlayed(brief.createdAt))`.
- **The context** sent is `openingContext(openingLine: clip?.text, brief: prep.current?.brief, briefAlreadyRaised: choice != OpeningChoice.brief, graphSummary: _buildGraphSummary())`.
- **Continuing a notebook** is unchanged: no greeting, and the context is only `[graph summary] …`.
- **`_writeSessionCard(notebookId)`** also fires `unawaited(service.requestBrief(notebookId).then((_) => prep.refresh(), onError: …log…))`, in parallel with the card request.

- [ ] **Step 1: Write the failing tests.**
  - `standard_opening_test.dart`: replace the sync test. The prompt contains `[opening said]` and doesn't contain the intro text.
  - `journal_session_lifecycle_test.dart` (fakes for prep and service):
    - with a usable brief, the first `client_content` text starts with `[opening said] "<brief line>"` and includes `[session brief]` with `"alreadyRaised":false`, and `markPlayed` is called once with the brief's `createdAt`;
    - with `prep.current == null`, the line is the returning clip's text and `markPlayed` isn't called;
    - with `knownNewAccount`, it's the intro text;
    - a continuing notebook sends no `[opening said]`.
  - `journal_joining_test.dart`: leaving a notebook calls `requestBrief(notebookId)` once and then `refresh`, and leaving still succeeds when `requestBrief` throws.
- [ ] **Step 2: Run and confirm they fail.** Run `flutter test test/standard_opening_test.dart test/journal_session_lifecycle_test.dart test/journal_joining_test.dart`. Expected: the new assertions fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the whole suite.** Run `flutter analyze && flutter test --exclude-tags perf; git checkout -- docs/assets pubspec.lock ios/Podfile.lock`. Expected: `No issues found!` and `All tests passed!`.
- [ ] **Step 5: Commit** with `feat(journal): open with the session brief, tell Gemini what was said`.

### Task 6: Contract doc

**Files:**
- Create: `contracts/session-brief-v1.md` (route request and response, the `get_session_brief` shape, field limits, the 21-day and one-play rules). Follow the tone of `contracts/retrieve-memory-v2` docs.

- [ ] **Step 1: Write it.** Every limit must match Tasks 1–2 (160, 140 ×4, 200, 24000 Hz, 21 days).
- [ ] **Step 2: Commit** with `docs(contracts): session brief v1`.

### Task 7: Deploy (with approval) and verify on the simulator

- [ ] **Step 1: Ask the user for approval** to apply migration `20261029000000` to `bjoevzvsdlhlcjywpyfx` and run `cdk deploy`. Show `supabase db push --linked --dry-run`, which must list only the new migration, and `npx cdk diff InfraStack`, which must show only additions: the brief function, role, log group, integration, permission and route. Stop if anything is modified or replaced.
- [ ] **Step 2: After approval, deploy.** Then probe `POST <runtime>/v1/notebooks/<zero-uuid>/brief` without auth. Expected: `401`.
- [ ] **Step 3: Simulator, returning account.**
  1. Leave a Just talk notebook after one typed turn. The logs show the card ready, and the brief route finishing within about 15 s.
  2. Open New notebook. The opener's words ask about that turn's topic, the `greeting playing` timing log appears at under 50 ms from the tap, as today, and the transcript's first Lumen row is the brief line.
  3. Open another new notebook. The fallback clip plays, because the brief has been used.
- [ ] **Step 4: Simulator, unknown state.** Kill the app, launch it offline or before the load finishes, and open New notebook immediately. The fallback plays, not the intro.
- [ ] **Step 5: Push and open a PR** into `fix/voice-echo-and-cold-start`, or into `main` if #21 has merged. The PR description lists what was verified.

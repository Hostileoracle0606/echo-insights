# Phase 3: keys only your devices hold (tickets)

**Status:** proposed · **Date:** 2026-11-15 · **Numbering:** LM-84 to LM-112

Privacy Phases 1 and 2 and the opt-in transcript erase (PRs #30 to #32) are merged to `main` and **not deployed**. This document turns the Phase 3 plan into scoped tickets. It follows the format of `docs/privacy-security-tickets.md` and `docs/privacy-follow-up-tickets.md` and continues their numbering at LM-84.

**Relation to LM-59 to LM-62.** Those four tickets were written before decisions D1 and D2. D1 is now settled as "no web reading in Phase 3" (the web app is out of scope, see LM-112) and D2 as "no escrow". The tickets below replace LM-59 to LM-62; LM-84 marks them superseded.

Nothing in this document is built, deployed or pushed.

**Owners.** "Claude" means an agent builds it, in a branch, with review. "User" means only the account owner can do it: a decision, a console step, a device check, a contract.

**Unverified.** A claim marked *(unverified)* has not been checked against the code, a vendor's documentation or a device. Check it before relying on it.

---

## Scope

- **In scope:** the iOS app (Flutter), Supabase (schema, RPCs, pg_cron jobs, pgTAP tests), the AWS Lambdas and the Supabase edge functions.
- **Out of scope:** the web app (`src/`, TanStack Start). It is future work, with one note ticket (LM-112) recording what must hold first.

## Decisions already made

1. **Keys live only on the user's own iOS devices** (Secure Enclave and Keychain). Neither the developer nor the server holds a key. Data is encrypted per user, so a database backup holds per-user ciphertext.
2. **No key escrow**, optional or otherwise. Losing every device and the recovery phrase means the journal is permanently unrecoverable.
3. **Processes that need text run one of two ways, chosen per job and written down in that job's ticket:**
   - **Device:** preferred. The server sees only ciphertext.
   - **One-request handover:** the device sends plaintext (or a key) for one request, the server uses it in memory and discards it. The ticket states exactly what the server sees and for how long.
4. **The encryption code is open-sourced**, and an independent audit is planned.
5. **Copy follows shipping.** Never claim "we can't read your journal" before it is true for that account. Never claim "keeps nothing". The Gemini Live voice path carries real names and audio, and pseudonymization does not apply to it.

---

## Facts about the code

**Checked 2026-11-15 on `main` (8817bed):**

- **36 migrations.**
- **Database tests:** `supabase/tests/database`, 28 files, about 5,000 lines. Their declared `plan()` counts add up to 1,032. The PR #32 run reported 1,088 passes; the gap is likely tests without a fixed plan, but I did not check that.
- **pg_cron jobs:**

  | Job | Schedule | Phase 3 effect |
  |---|---|---|
  | `embed-reconcile` | every 15 minutes | Reads entity text to build vectors. Breaks under encryption. |
  | `embed-orphan-prune` | every 30 minutes | Works on ids only. Unaffected. |
  | `forget-old-transcripts` | daily at 03:15 | Deletes by date. Unaffected. |

- **Edge functions:** four deployable folders (`embed-entities`, `extract-graph`, `retrieve-memory`, `speak-agent`) plus `_shared`. The earlier count of five probably included `_shared`. Legacy `extract-graph` is already slated for deletion (LM-67).
- **The opt-in erase from PR #32 runs on the phone.**
  - `lib/services/memory_control_service.dart` calls `forget_erase_step` and `forget_erase_pending`. No pg_cron job drives it.
  - `lib/providers/voice_services_provider.dart` resumes an erase that was cut short. It runs after launch and again on every resume, without holding up a session.
- **How a session saves:**
  - It saves turn by turn, not on a timer.
  - Each finished turn is written to an on-device turn journal (`lib/services/turn_journal_service.dart`, protected local file), and so is its prepared commit.
  - `commit_notebook` then runs with a request id. The server's idempotency ledger (`notebook_commit_requests`, primary key `(notebook_id, request_id)`, keyed on a payload hash) replays a commit it already applied.
  - A failed RPC is retried with the same request id (`lib/providers/journal_provider.dart`, around line 893).
- **Catch-up for an unfinished session already exists, but only in part:**
  - **Turns:** unsaved turns from the turn journal are restored and replayed when *that notebook is opened* (`_restoreTurnsForNotebook`, called from open, about line 1341). Nothing sweeps every notebook at launch.
  - **Closing card:** `lib/services/session_card_service.dart` retries the close twice, with backoff, inside the call. I found no retry of a missing card at launch (*unverified* beyond a search of `lib`).
  - **Brief:** retried on resume (`openingPrep.retryPendingBrief`).
- **Background work on iOS:** none. There is no `BGTaskScheduler`, no `beginBackgroundTask` and no `UIBackgroundModes` in `ios/Runner` or `lib`.
- **Keychain classes in use today:**
  - App lock: `unlocked_this_device`.
  - Name map (`pseudonym_store.dart`): `first_unlock_this_device`.
- **Auto-forget's follow-up** (`…360`) adds `notebooks.transcript_forgotten_at`. `close-session` reads it to avoid writing a partial card. That is a timestamp flag, with no text involved.

**From the 2026-11-15 count, not re-checked here:**
- 77 SQL functions, 27 of which concern redaction, forgetting or suppression and read plaintext names.
- 4 Lambdas, about 3,300 lines.
- 113 Flutter test files and 10 infra test files.

**Text-reading components that Phase 3 must change:**
- `close-session`: the closing card and the next brief.
- `extract-graph`: the runtime Lambda route, not the legacy edge function.
- Embeddings and memory search.
- The forget redaction functions.
- Export.
- Auto-forget.
- The pgTAP tests.

**Unaffected (they carry no journal text):**
- `live-session`, which mints Gemini tokens.
- `supabase-authorizer`.
- `embed-orphan-prune`.
- `forget-old-transcripts`.

---

## Summary

| Ticket | Title | Owner | Blocker? | Effort (estimate) |
|---|---|---|---|---|
| LM-84 | Phase 3 design spec | Claude | Blocks all Phase 3 build tickets | 3–5 days |
| LM-85 | Decision: Forget rule, time-scoped or blocked forever | User | Blocks LM-96 | under 1 day |
| LM-86 | Decision: make the transcript erase the default | User | Blocks LM-96, LM-99 | under 1 day |
| LM-87 | Decision: on-device name parser | User | Blocks nothing in Phase 3 | under 1 day |
| LM-88 | Decision: Keychain accessibility class for the key | User | Blocks LM-90, LM-104 | under 1 day |
| LM-89 | Decision: how a second iPhone gets the key | User | Blocks LM-90, LM-107 | under 1 day |
| LM-90 | Key management module | Claude | Blocks LM-91 to LM-107 | 1–2 weeks |
| LM-91 | Recovery phrase: flow and copy | Claude, User (copy sign-off) | Blocks LM-106 | 1 week |
| LM-92 | Encrypted columns and ciphertext-only writes | Claude | Blocks LM-93 to LM-100 | 1–2 weeks |
| LM-93 | `close-session`: card and brief under encryption | Claude | Phase 3 blocker | 1 week |
| LM-94 | Extraction and graph merge on the device | Claude | Phase 3 blocker | 2–3 weeks |
| LM-95 | Embeddings and memory search on the device | Claude | Phase 3 blocker | 2–3 weeks |
| LM-96 | Forget and redaction on the device | Claude | Phase 3 blocker | 2–3 weeks |
| LM-97 | Export decrypted on the device | Claude | Phase 3 blocker | 2–4 days |
| LM-98 | Auto-forget under encryption | Claude | Phase 3 blocker | 1–2 days |
| LM-99 | Opt-in transcript erase under encryption | Claude | Phase 3 blocker | 3–5 days |
| LM-100 | pgTAP and test-suite rewrite | Claude | Phase 3 blocker | 1–2 weeks |
| LM-101 | Gemini Live voice path: state it, don't change it | Claude | Copy blocker only | 1 day |
| LM-102 | Idempotency keys for every text step | Claude | Phase 3 blocker | 1 week |
| LM-103 | Launch-time catch-up | Claude | Phase 3 blocker | 1 week |
| LM-104 | Background tasks on iOS | Claude, User (device runs) | Not a blocker (improves delay) | 1–2 weeks |
| LM-105 | Backups: short-lived pre-deploy backup; encrypted suppression entries | User (backup), Claude (schema) | Backup step blocks the current deploy | 1–3 days |
| LM-106 | Migrate existing journals on the device | Claude | Blocks "can't read" copy | 1–2 weeks |
| LM-107 | Devices, revocation and key rotation | Claude | Phase 3 blocker | 1–2 weeks |
| LM-108 | Open-source the encryption code | Claude, User (licence, repo) | Blocks the audit | 2–4 days |
| LM-109 | Independent audit and pen-test scope update | User | Blocks "can't read" copy | weeks (external) |
| LM-110 | iOS copy and claims, gated per feature | Claude, User (sign-off) | Phase 3 blocker | 3–5 days |
| LM-111 | Rollout plan that does not block the current deploy | Claude | Not a blocker | 1–2 days |
| LM-112 | Web app: note ticket (no build) | User | Blocks any web work | under 1 day |

The efforts are estimates for planning, not measurements. Tickets that need a measurement make it their first step.

---

## Design

### LM-84: Phase 3 design spec
**Owner:** Claude · **Effort (estimate):** 3–5 days

**Why**
The build tickets touch keys, the schema, every text-reading job and the app's lifecycle. Without one agreed design, they will drift apart. LM-59 to LM-62 assumed web unlock and optional escrow, and both have now been decided against.

**Scope**
Write `docs/superpowers/specs/<date>-zero-access-journal-design.md` covering:
- **Keys and encryption:**
  - Key creation, and the key hierarchy: a user master key, per-notebook keys wrapped by it, and a separate key for the suppression list (LM-105).
  - The library: a well-reviewed one, AES-GCM or XChaCha20-Poly1305, with no custom cryptography. Name the library and its version.
  - Nonce handling, and what each ciphertext's associated data binds (user id, notebook id, row id, column) so rows can't be swapped between users or notebooks.
- **Protecting the keys:**
  - Secure Enclave wrapping of the master key, and the Keychain accessibility class (from LM-88).
  - iCloud Keychain sync, or recovery-phrase-only (from LM-89).
  - The recovery phrase: format, word list and how it derives a key (a memory-hard KDF, with parameters stated).
  - Rotation: per-notebook keys, the master key, and what a revoked device can still read.
  - File protection classes for every local file holding plaintext or keys.
- **Per-user scoping:** every row's ciphertext is decryptable only with that user's keys, and a database backup is per-user ciphertext.
- **Data:** a table of every column that holds journal text today, saying whether it becomes ciphertext, stays as metadata, or is dropped.
- **Text jobs:** a table of every job that reads text, saying "device" or "one-request handover", what the server sees, and for how long. LM-93 to LM-99 then implement it.
- **Failure handling:** the failure and delay model (LM-102 to LM-104).
- **Search:** what the server can still infer: timestamps, sizes, notebook counts, revision counts, the order of edits. State it plainly.

**Steps**
1. Read LM-59 to LM-62, this document and the Phase 1 and 2 code paths listed under "Facts".
2. Wait for the decisions in LM-88 and LM-89, which the key design needs. LM-85 to LM-87 can come later.
3. Write the spec; review it with the user.
4. Add a line to `docs/privacy-security-tickets.md` marking LM-59 to LM-62 as superseded by LM-84 onwards. This is a doc change only.

**Acceptance criteria**
- The spec names the library, the KDF and its parameters, the nonce scheme and the associated data.
- Every text-holding column and every text-reading job appears in a table, with a decision.
- The "what the server can still see" section exists and is in plain words.
- The user has approved it.

**Dependencies:** LM-88, LM-89.

**Out of scope:** the web app (LM-112); confidential inference (option D in the privacy design); changing the Gemini Live voice path.

---

## Decisions

Each decision ticket gives options and a recommendation. The user decides. No dependent build work starts before the decision.

### LM-85: Decision: Forget rule, time-scoped or blocked forever
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
Today, forgetting a person blocks that name for good. Lumen never brings it up again, and a later mention is redacted (LM-49, LM-63). Under encryption, the server can't check names, so the device enforces the rule (LM-96). The rule decides how big that job is.

**Options**
- **A. Keep "blocked forever".** The suppression list stays and is checked on every turn, on the device. It's the strongest promise. The cost is a list that grows forever. A new person with the same name (a new colleague called Maya Chen) can never be remembered without an "unforget".
- **B. Time-scoped.** Text from before the forget time stays suppressed; anything said afterwards starts a fresh record. It's simpler and lets people re-meet a name. It weakens the promise: if the user talks about the same person again, Lumen remembers that new talk.
- **C. Time-scoped plus an explicit "unforget".** It is option A, with a control to lift the block.

**Recommendation:** **A, with "unforget" added later if people ask for it.** It matches the user ruling of 2026-11-11 ("should never bring up forgotten context across any of its features"). The device-side check is cheap for lists of realistic size. Measure that as the first step of LM-96.

**Acceptance criteria:** the decision and its reason are recorded in the SDD ledger and in LM-84's spec.

**Dependencies:** none. **Out of scope:** building any of it.

### LM-86: Decision: make the transcript erase the default
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
PR #32 lets a user opt in to replacing a forgotten multi-word name in their own saved transcripts. If that were the default, those names would no longer need a suppression entry for past text. They would still need one to block future mentions under option A of LM-85.

**Options**
- **A. Keep it opt-in.** The user's own words stay as they said them.
- **B. Make it the default for multi-word names**, with an opt-out.
- **C. Make it the default for all names.** This was rejected by ruling R34, because single words such as "Will" or "May" would rewrite ordinary words.

**Tradeoff:** the erase rewrites the user's own journal, and it can't be undone (there is no escrow and no server copy). It removes the risk that a forgotten name survives in stored text. It does not remove the need to block future mentions.

**Recommendation:** **A, keep it opt-in.** A journal app that silently rewrites what someone said, irreversibly, breaks a different trust. The suppression list is still needed for future text under LM-85 A.

**Acceptance criteria:** the decision is recorded; LM-99 and LM-110 copy follow it.

**Dependencies:** LM-85 (the two interact). **Out of scope:** single-word erase.

### LM-87: Decision: on-device name parser
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
Recall and Forget both depend on spotting names. Today that is a deterministic list match plus slugs. A parser (entity linking and coreference: "my sister", "she") would catch more.

**Options**
- **A. No parser.** Keep the deterministic list.
- **B. An on-device parser for recall only**, with the list as the backstop for Forget.
- **C. A cloud model.** Rejected: it would see the names Phase 2 hides.

**Tradeoffs**
- A parser misses silently: a missed "my sister" leaks without any error.
- Pronouns are hard, and quality varies by language.
- A model adds size and battery cost on the phone. Both are unmeasured.

**Recommendation:** **A for Phase 3. Revisit B after Phase 3 ships**, with a measurement first (model size, latency per turn, recall on synthetic transcripts). Forget must never depend on it.

**Acceptance criteria:** the decision is recorded. If B is chosen, a separate ticket is written, with measurement as step 1.

**Dependencies:** none. **Out of scope:** building a parser.

### LM-88: Decision: Keychain accessibility class for the key
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
The class decides whether the app can decrypt while the phone is locked. It sets what background work (LM-104) can do.

**Options**
- **A. `afterFirstUnlockThisDevice`** (what the name map uses today).
  - The key is readable after the first unlock since boot, even while the phone is locked.
  - Background tasks can finish a card, an extraction or vectors while the phone is in a pocket.
  - Weaker against someone who has the phone after one unlock and can run code on it.
- **B. `whenUnlockedThisDevice`** (what app lock uses today).
  - The key is readable only while the phone is unlocked.
  - Background work can't decrypt while the phone is locked, so text jobs wait until the next unlock.
  - Stronger at rest.
- **C. A mix:** the master key under B. A narrowly scoped, short-lived working key under A, holding only what pending jobs need, deleted when the queue is empty.
- **"ThisDevice" variants:** these never sync through iCloud Keychain. That interacts with LM-89.

**Recommendation:** **C, falling back to B if the spec review finds C too complex.** Delay is acceptable ("design for delay, not loss"). C keeps background completion possible without leaving the master key readable while the phone is locked.

**Acceptance criteria:** the decision is recorded; LM-84 uses it.

**Dependencies:** none. **Out of scope:** app lock's own class (already `unlocked_this_device`).

### LM-89: Decision: how a second iPhone gets the key
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
Someone with two iPhones (or a replacement phone) needs the key on both. The two ways to get it there have different trust models.

**Options**
- **A. iCloud Keychain sync.**
  - Seamless: the second phone just works.
  - Apple says iCloud Keychain is end-to-end encrypted *(unverified for the specific item attributes the spec will use: check Apple's Platform Security guide)*. Key safety then depends on the user's Apple ID security.
  - Sync needs a synchronizable (non-"ThisDevice") item. That conflicts with LM-88's "ThisDevice" classes.
- **B. Recovery phrase only.** The user types the phrase on each new phone. The key never leaves a device except in the user's head or on paper. It's more friction, and the phrase is needed more often, so it is more likely to be written down somewhere unsafe.
- **C. Device-to-device transfer.** The old phone shows a QR code or uses a nearby secure channel, and the phrase is the fallback. It needs the old phone to be present.

**Recommendation:** **B for the first release, with C as a follow-up.** It keeps the claim simple ("only your devices and your phrase"). It avoids the Keychain-class conflict with LM-88. It also keeps Apple's sync out of the trust story. Revisit A if friction shows up in testing.

**Acceptance criteria:** the decision is recorded; LM-84 and LM-107 use it.

**Dependencies:** LM-88 (the classes interact). **Out of scope:** web or Android devices.

---

## Keys and storage

### LM-90: Key management module
**Owner:** Claude · **Effort (estimate):** 1–2 weeks

**Why**
Everything else needs keys that are created, stored, wrapped and unwrapped correctly, and that are testable.

**Scope**
- One Dart module, plus native code where Secure Enclave or Keychain access needs it.
- Create the master key; wrap and unwrap per-notebook keys.
- Encrypt and decrypt with associated data.
- Store keys under the LM-88 class; derive from and restore with the recovery phrase.
- No other part of the app touches key bytes directly.

**Steps**
1. Measure: encrypt and decrypt time and memory for a realistic notebook (sizes taken from the current data, counts only), on the oldest supported iPhone. Write the numbers into the ticket.
2. Build the module behind an interface, with a fake for tests.
3. Wire Secure Enclave wrapping and the Keychain class from LM-88.
4. Keep the encryption code in its own folder with its own licence header, ready for LM-108.

**Acceptance criteria**
- Unit tests: round trip; decryption fails with a wrong key, a tampered ciphertext or changed associated data; the phrase restores the same keys.
- No key bytes in logs. The log scan from LM-44 covers the new code.
- The step-1 measurements are recorded.

**Dependencies:** LM-84, LM-88, LM-89.

**Out of scope:** recovery UX (LM-91), devices (LM-107).

### LM-91: Recovery phrase: flow and copy
**Owner:** Claude (build), User (copy sign-off) · **Effort (estimate):** 1 week

**Why**
With no escrow, the phrase is the only way back after losing every device. People need to understand that before they rely on it, not after.

**Scope**
- **Creation:** shown once, at setup, with a plain explanation before it appears.
- **Confirmation:** the user re-enters selected words; setup doesn't finish until they do.
- **Re-entry** on a new device and after a reinstall.
- **Later:** "Show my recovery phrase", behind re-authentication (LM-47's re-auth).
- **The permanent-loss warning, in plain words.** Draft, for sign-off: "If you lose all your devices and this phrase, your journal is gone for good. We can't get it back, because we never have your key. That's the point."
- Never put the phrase in screenshots, the clipboard or backups. Block screenshots on that screen where iOS allows it *(unverified: check current iOS behaviour)*.

**Steps**
1. Draft the copy and screens; the user signs off on the copy.
2. Build creation, confirmation and re-entry.
3. Device-test the flows (LM-65 style).

**Acceptance criteria**
- Setup can't complete without confirmation.
- A wrong phrase is refused, with no hint of which word is wrong beyond what the word list allows.
- Re-entry on a second simulator restores access to the same journal.
- The loss warning appears before the phrase is shown and again at confirmation.
- The user has signed off on the copy.

**Dependencies:** LM-90.

**Out of scope:** escrow (decided against); a paper backup service.

### LM-92: Encrypted columns and ciphertext-only writes
**Owner:** Claude · **Effort (estimate):** 1–2 weeks

**Why**
The schema must store ciphertext for every text column. The RPCs must accept and return ciphertext without reading it.

**Scope**
- Add ciphertext columns, or change types, for:
  - turns (`conversation_turns`, including `context_text`);
  - entries;
  - cards and briefs;
  - entity names, descriptions and metadata;
  - relation labels and metadata;
  - follow-ups and asked questions;
  - the suppression list (LM-105).
- Keep ids, timestamps and revisions in plaintext. LM-84 lists what that reveals.
- RPCs that write text (`commit_notebook`, the save functions) take ciphertext plus a key id, and check sizes only. LM-46's caps apply to ciphertext length.
- Plaintext and ciphertext coexist during migration (LM-106). Each row has a flag recording which one it holds.

**Steps**
1. Forward migrations only, staging first.
2. Update the RPCs and their caps.
3. Update the size-cap tests.

**Acceptance criteria**
- pgTAP: a plaintext write to an encrypted account is refused; the size caps hold on ciphertext; RLS is unchanged.
- No RPC decrypts. The server holds no key.

**Dependencies:** LM-84, LM-90.

**Out of scope:** moving the logic that reads text (LM-93 to LM-99).

---

## Text-reading components

Each ticket states where the job runs, what the server sees and for how long, what changes, and which tests are affected.

### LM-93: `close-session`: card and brief under encryption
**Owner:** Claude · **Effort (estimate):** 1 week

**Runs:** one-request handover. The device can't call Gemini Flash without exposing the API key, and the Lambda exists to hold the key.

**What the server sees, and for how long**
- **The Lambda:** the pseudonymized turns from the device, in memory, for one request. Phase 2's name swap still applies.
- **Gemini:** the same pseudonymized text, under the paid-API terms (LM-43).
- **Database:** neither writes plaintext. The Lambda returns the card and brief text to the device, which encrypts and saves them.
- **TTS for the brief opener:** it receives the real name today (LM-56 decision). State whether that still holds.

**What changes**
- `close-session` stops reading turns from the database and stops calling `save_session_card` and `save_session_brief` with plaintext.
- It reads `transcript_forgotten_at` as before; that is a flag, not text.

**Tests affected:** the infra tests for `close-session`, `test/` card and brief service tests, and pgTAP for the save functions.

**Acceptance criteria**
- A test asserts that the Lambda writes nothing to the database except ciphertext forwarded by the device.
- The log-content test (LM-44) still passes.
- A card and a brief round-trip end to end on a simulator.

**Dependencies:** LM-92, LM-102.

**Out of scope:** changing the card or brief prompts.

### LM-94: Extraction and graph merge on the device
**Owner:** Claude · **Effort (estimate):** 2–3 weeks

**Runs:**
- **The model call:** one-request handover through the runtime's extraction route.
- **Graph merging** (today's `_commit_apply_turn` in SQL): on the device.

**What the server sees, and for how long**
- **The Lambda:** pseudonymized turn text plus the pseudonymized "existing entities" list, in memory, for one request.
- **The database:** only ids, revisions and ciphertext.

**What changes**
- Port `_commit_apply_turn`'s merge rules (deduplication, aliases, suppression checks) to Dart.
- `commit_notebook` becomes a ciphertext store with revision checks.
- The Lambda's call to `redact_forgotten_text` moves to the device, which redacts before sending (LM-96).

**Tests affected:** the merge tests in `test/`, the commit pgTAP tests, the infra extraction tests, and `test/memory_recall_scenarios_test.dart`.

**Steps**
1. Measure merge time on the device for the largest current notebook (counts only).
2. Port the rules, with the existing pgTAP cases translated to Dart tests one for one.
3. Switch over.

**Acceptance criteria**
- Every merge case covered by pgTAP today has a passing Dart equivalent.
- The recall scenarios pass.
- The server stores no plaintext from extraction.

**Dependencies:** LM-92, LM-96, LM-102.

**Out of scope:** the name parser (LM-87).

### LM-95: Embeddings and memory search on the device
**Owner:** Claude · **Effort (estimate):** 2–3 weeks

**Runs:** on the device.

**What the server sees, and for how long:** encrypted vectors, or none at all if they are kept only locally (decide in LM-84).

**What changes**
- Retire the `embed-reconcile` pg_cron job and the `embed-entities` edge function.
- Remove `retrieve-memory`'s server-side vector search, so the device searches by brute force.
- `embed-orphan-prune` either stays (ids only) or goes with the vectors.

**Steps**
1. Measure, on the oldest supported iPhone:
   - gte-small's size and load time;
   - time to embed one entity;
   - search time over the largest current graph;
   - battery cost of a full re-embed.

   If the numbers are unacceptable, stop and bring them back to the user.
2. Build on-device embedding and search.
3. Retire the server jobs in a forward migration.

**What lags:** after a new entity, vectors are built when the device next has time (LM-103, LM-104). Search over that entity may lag until then.

**Tests affected:** `retrieve-memory` Deno tests (45 to 60 today), the embedding pgTAP tests, the recall scenarios.

**Acceptance criteria**
- The step-1 numbers are recorded and accepted by the user.
- Recall scenarios pass with on-device search.
- `embed-reconcile` is unscheduled.
- No server code path reads entity text.

**Dependencies:** LM-90, LM-92.

**Out of scope:** a better embedding model.

### LM-96: Forget and redaction on the device
**Owner:** Claude · **Effort (estimate):** 2–3 weeks

**Runs:** on the device. The server can't check names it can't read.

**What the server sees, and for how long:** encrypted suppression entries (LM-105) and ciphertext. Nothing in plaintext.

**What changes**
- The 27 SQL functions that read plaintext names move to the device, or are retired. Their count is from the 2026-11-15 count, not re-checked; list them by name in step 1. They include `redact_forgotten_text`, the forget previews and the suppression checks.
- `forget_entity` becomes:
  1. the device decrypts the relevant rows;
  2. it redacts them;
  3. it re-encrypts;
  4. it writes them back with revision checks.
- The device then adds an encrypted suppression entry.
- Every handover (LM-93, LM-94) is redacted on the device before it leaves.
- The rule implemented is the one decided in LM-85.

**Steps**
1. List every function that reads plaintext names, and say for each whether it moves to the device, is kept with only ids, or is retired.
2. Measure redaction time over the largest notebook and the largest realistic suppression list.
3. Port the redaction with the existing pgTAP cases translated one for one. Those cases include the critical ones: capitalized single words, structural keys, names of four or more tokens and non-Latin names.

**Acceptance criteria**
- Every C1, C2 and R1 to R3 case from the final-review findings passes on the device.
- A forgotten name never appears in any handover payload, which a test intercepts and checks.
- The cross-device marker (`forgotten_marker`) still works.

**Dependencies:** LM-85, LM-86, LM-92, LM-105.

**Out of scope:** single-word erase; the name parser.

### LM-97: Export decrypted on the device
**Owner:** Claude · **Effort (estimate):** 2–4 days

**Runs:** on the device.

**What the server sees, and for how long:** nothing new. `export_my_data` returns ciphertext.

**What changes:** the app decrypts and builds the zip locally. The zip may linger in a temp folder for up to an hour (existing note), so the copy must still not say "deleted immediately".

**Tests affected:** `journal_export_service` tests and the export pgTAP test (its fixture is hand-written, LM-83).

**Acceptance criteria:** an export from an encrypted account opens and contains readable text; the server response is ciphertext only.

**Dependencies:** LM-92.

**Out of scope:** web export.

### LM-98: Auto-forget under encryption
**Owner:** Claude · **Effort (estimate):** 1–2 days

**Runs:** on the server, by date only. The daily `forget-old-transcripts` job at 03:15 deletes rows by timestamp. It works unchanged on ciphertext rows.

**What the server sees:** timestamps. It sees no text, as today.

**What changes:** check that no part of `…350` and `…360` reads text. From reading `…360`, the follow-up is a timestamp flag; check `…350`'s sweep body too. Make sure the flag still stops `close-session` from writing a partial card.

**Acceptance criteria:** a pgTAP test runs the sweep against ciphertext rows and checks that the right rows go.

**Dependencies:** LM-92.

**Out of scope:** changing retention periods.

### LM-99: Opt-in transcript erase under encryption
**Owner:** Claude · **Effort (estimate):** 3–5 days

**Runs:** on the device. It already does: the app drives `forget_erase_step` in batches and resumes on launch and on resume.

**What the server sees:** a job row with counts; the rewritten rows come back as ciphertext.

**What changes:** each batch becomes:
1. fetch the ciphertext;
2. decrypt;
3. replace the name (multi-word names only, per R34);
4. re-encrypt;
5. write back with revision checks.

The SQL replacement inside `forget_erase_step` is retired.

**Acceptance criteria**
- An erase interrupted at a batch boundary resumes and finishes with no double replacement.
- The behaviour follows the default decided in LM-86.

**Dependencies:** LM-86, LM-92, LM-96, LM-102.

**Out of scope:** single-word erase.

### LM-100: pgTAP and test-suite rewrite
**Owner:** Claude · **Effort (estimate):** 1–2 weeks

**Why**
Many database tests assert on plaintext. Once the server can't read text, those assertions move to the device, or change to ciphertext and ids.

**Scope**
- **Database tests:** 28 files and about 5,000 lines in `supabase/tests/database`. Classify each test as kept, changed to ciphertext, or moved to Dart.
- **New tests:** no plaintext column is written for an encrypted account; RLS still isolates users; size caps apply to ciphertext.
- **CI:** keep `.github/workflows/privacy-tests.yml` green throughout.

**Acceptance criteria**
- Every moved test has a named Dart equivalent.
- The total count of assertions doesn't drop without a written reason.
- CI is green.

**Dependencies:** LM-92 to LM-99, in step with each.

**Out of scope:** the flaky-test hunt (LM-83).

### LM-101: Gemini Live voice path: state it, don't change it
**Owner:** Claude · **Effort (estimate):** 1 day

**Why**
Live voice sends real audio and real names to Google. Phase 3 encrypts storage; it doesn't change this path, and pseudonymization doesn't apply to it.

**Scope**
- A paragraph in LM-84's spec and in the "Who hears you" screen saying what Live sees.
- Check that no Phase 3 copy implies otherwise.

**Acceptance criteria:** the copy test (`test/privacy_copy_test.dart`) asserts that the Live line is present wherever storage encryption is claimed.

**Dependencies:** LM-110.

**Out of scope:** replacing Gemini Live (later work: on-device or open voice).

---

## Resilience: design for delay, not loss

With keys only on the device, the server can't finish text work while the phone is away. Every step must be safe to repeat, and the phone must pick up whatever is unfinished.

### LM-102: Idempotency keys for every text step
**Owner:** Claude · **Effort (estimate):** 1 week

**Why**
A retry after a crash, a timeout or a background task must never duplicate a card, an entity or a vector.

**Scope**
- **Existing:** `commit_notebook` already has a ledger, `notebook_commit_requests` with key `(notebook_id, request_id)` and a payload hash.
- Extend the same pattern to:
  - the card and the brief, keyed by notebook and revision;
  - extraction, keyed by turn id;
  - vector builds, keyed by entity id and content hash;
  - erase batches, keyed by job and batch.
- **Reads:** a repeat read must be safe too. "Is there a card for revision N?" must have a definite answer.

**Acceptance criteria:** for each step, a test runs it twice with the same key and checks for one result and no duplicates. A third run with a changed payload under the same key is refused.

**Dependencies:** LM-92.

**Out of scope:** retry timing (LM-103).

### LM-103: Launch-time catch-up
**Owner:** Claude · **Effort (estimate):** 1 week

**Why**
Today unsaved turns replay only when that notebook is opened, and the card retries only inside the close call. Under encryption, nothing else can finish the work. The app has to, every time it starts.

**Scope**
- On launch and on resume, after unlock:
  - find every notebook with unfinished work (turns not committed, no card for the latest revision, entities without vectors, erase jobs pending);
  - finish it in order, using LM-102's keys.
- Bounded and non-blocking: a session can start while catch-up runs. The open notebook goes first.
- A small "finishing up" state in the UI if a card is still pending, with no alarming copy.

**Acceptance tests (one per failure case)**
1. **Crash or OS kill mid-session:** kill the app after a turn is journalled but before commit. On relaunch, without opening the notebook, the turn is committed and the card follows.
2. **Offline at session end:** end a session with the network off. When the network returns (relaunch or resume), the card and brief are produced exactly once.
3. **Force quit:** force-quit right after ending a session. On the next launch, everything finishes. This is a simulator approximation; LM-104 checks it on a device.
4. **Search vectors lagging:** add an entity, then search before its vector exists. The result says nothing wrong, and the vector is built on the next catch-up.
5. **Second iPhone:** a session ended on phone A while phone A is then lost. Phone B, after phrase entry (LM-89), finishes A's unfinished server-side steps that need only ciphertext. Turns that were only in A's local journal are lost; the copy says so.

**Acceptance criteria:** all five tests pass on a simulator. Case 5 needs two simulators.

**Dependencies:** LM-102, LM-90.

**Out of scope:** iOS background execution (LM-104).

### LM-104: Background tasks on iOS
**Owner:** Claude (build), User (device runs) · **Effort (estimate):** 1–2 weeks

**Why**
Finishing work after the user leaves the app shortens the delay. Today the app has no background work at all.

**Scope**
- **Grace period:** when the app goes to the background with nearly finished work (a card mid-request), ask iOS for extra time to finish it.
- **Scheduled tasks** (`BGTaskScheduler`): register a processing or refresh task that runs catch-up (LM-103) and ends as soon as it's done.
- **Key access:** depends on LM-88. Under class B, background tasks can do only work that needs no decryption.

**Limits to state honestly, not promise around**
- iOS decides when scheduled tasks run, and may not run them for a long time.
- A force quit generally stops them until the user opens the app again *(unverified for current iOS: confirm)*.
- Time limits for both mechanisms *(unverified: check Apple's current documentation, and measure in step 1, before any copy mentions a time)*.

**Steps**
1. Measure on a real device, over several days of normal use: how often scheduled tasks run, how much time they get, and the grace period actually granted. Record the numbers.
2. Build the grace-period request and the scheduled task.
3. Add `UIBackgroundModes` and the task identifiers to `Info.plist`.

**Acceptance criteria**
- The step-1 numbers are recorded.
- On a device: leave the app mid-card, and the card completes within the grace period when there is time.
- A scheduled task finishes pending work and ends.
- No copy promises background completion.

**Dependencies:** LM-88, LM-103.

**Out of scope:** push-triggered background work (the server can't decrypt anyway).

---

## Backups

### LM-105: Backups: a short-lived pre-deploy backup; encrypted suppression entries
**Owner:** User (the backup), Claude (schema) · **Effort (estimate):** 1–3 days

**Why**
- **The current deploy:** migration `…200` rehashes the suppression list one way, so the deploy needs a backup first. A backup holds every user's journal in plaintext until Phase 3 ships, so it must be short-lived, with a written deadline.
- **Phase 3:** the one-way hash exists because the server held the list. Under Phase 3, the list is encrypted per user instead.

**Scope, part 1: the pre-deploy backup (for the current deploy, before Phase 3)**
- Before applying the 18 migrations, take one backup of the production database.
- Write down where it is stored, who can reach it, its retention (proposed: delete 14 days after the deploy is verified, adjustable by the user), and the deletion date.
- Check Supabase's own automatic backup retention *(unverified: check the plan)*. Record it, because those backups also hold plaintext.
- Delete the manual backup on the date, and record that it was done.

**Scope, part 2: encrypted suppression entries (Phase 3)**
- Each forgotten name is stored as ciphertext under the user's key, not as a keyed hash.
- The device decrypts the list to check names (LM-96).
- Migration from the hashes: the device can't turn hashes back into names. It can only match hashes against names it already knows (its own entity names and transcripts). Hashes it can't match stay as hashes; the device still uses them for exact-slug checks.

**Acceptance criteria**
- Part 1: a written record (in `docs/security/admin-access.md` or the incident log) with date, location, retention and the deletion confirmation.
- Part 2: pgTAP shows the server stores no plaintext or hash of new suppressions. A Dart test shows a migrated account still blocks a forgotten name.

**Dependencies:** part 1 has none and is due before the current deploy; part 2 needs LM-90 and LM-92.

**Out of scope:** encrypting Supabase's platform backups (not in our control).

### LM-106: Migrate existing journals on the device
**Owner:** Claude · **Effort (estimate):** 1–2 weeks

**Why**
Existing accounts hold plaintext on the server. "We can't read it" is false for an account until its data has been converted and the plaintext deleted.

**Scope**
- A one-time, resumable job on the device, per account:
  1. download in batches;
  2. encrypt;
  3. upload with revision checks;
  4. then delete the plaintext on the server.
- Progress is shown; the app stays usable.
- A per-account flag records completion. Copy (LM-110) reads it.

**Acceptance criteria**
- Interrupted at any batch, it resumes with nothing lost or duplicated.
- At the end, a pgTAP query finds no plaintext for that account.
- The plaintext is deleted only after its ciphertext is confirmed.

**Dependencies:** LM-91 (the phrase must exist before the data depends on it), LM-92, LM-102.

**Out of scope:** migrating data out of old platform backups, which age out under part 1's deadline and the platform's retention.

### LM-107: Devices, revocation and key rotation
**Owner:** Claude · **Effort (estimate):** 1–2 weeks

**Why**
A lost or sold phone must not keep reading new entries.

**Scope**
- **Adding a device:** follows LM-89.
- **Revoking a device:** it ties into the device list (LM-58) for sign-out. Rotate the keys for new data, and re-wrap the per-notebook keys.
- **Key rotation**, as LM-84 specifies.
- **What a revoked device can still read:** anything it already downloaded. State this plainly.

**Acceptance criteria:** after revocation and rotation, a simulator acting as the revoked device can't decrypt entries written afterwards; the remaining device can read everything.

**Dependencies:** LM-89, LM-90, LM-92.

**Out of scope:** remote wipe of a lost device's local files (iOS's job).

---

## Proof

### LM-108: Open-source the encryption code
**Owner:** Claude (prepare), User (licence, repository, publishing) · **Effort (estimate):** 2–4 days

**Why**
"Show proof rather than claims" (principle 6). People and auditors should be able to read the code that protects their journal.

**Scope**
- The LM-90 module, the recovery phrase derivation and the file-protection code.
- Pick a licence (the user's decision), and publish a separate repository or a public folder (the user's decision).
- A README stating the threat model and what the code does not protect (the voice path, metadata).

**Acceptance criteria:** the code builds from the public source, its tests pass there, and the app uses exactly that code (pinned by version or commit).

**Dependencies:** LM-90. **Out of scope:** open-sourcing the whole app.

### LM-109: Independent audit and pen-test scope update
**Owner:** User · **Effort (estimate):** weeks (external)

**Why**
The "can't read it" claim needs an outside check before it is made.

**Scope**
- Book a cryptography audit of the published code (LM-108) and of the key handling in the app.
- Update `docs/security/pentest-scope.md` with:
  - the new trust boundaries;
  - the handover endpoints (LM-93, LM-94);
  - background tasks;
  - the recovery flow.

**Acceptance criteria:** the audit report is received, with each finding fixed or accepted in writing, and no open Critical or High.

**Dependencies:** LM-108, the build tickets.

**Out of scope:** paying for a bug bounty (separate decision).

---

## Copy and rollout

### LM-110: iOS copy and claims, gated per feature
**Owner:** Claude (build), User (sign-off) · **Effort (estimate):** 3–5 days

**Why**
Copy follows shipping. Each Phase 3 claim must appear only once it is true for that account.

**Scope**
- Add Phase 3 features to the gated-claim system in `lib/privacy/privacy_claims.dart` (`PrivacyFeature`, `shipped`).
- **Claims and their gates:**

  | Claim | Shown only when |
  |---|---|
  | "Your journal is locked with a key only your devices hold" | The account's migration (LM-106) is complete |
  | "We can't read your journal" | Above, **and** the audit (LM-109) is closed |
  | Recovery phrase loss warning | Always, from setup (LM-91) |

- **Lines that stay as they are:**
  - The Gemini Live line, which states real names and audio (LM-101).
  - Never "keeps nothing".
  - The handover line, which must not say "keeps nothing". Draft: "To write your card, Lumen sends a version with names swapped out to our server for that one request. It isn't stored."
- `test/privacy_copy_test.dart` checks every gate.

**Acceptance criteria**
- No Phase 3 claim renders for an account whose migration isn't complete.
- The copy test covers each gate.
- The user signs off on the wording.

**Dependencies:** LM-91, LM-101, LM-106, LM-109.

**Out of scope:** the web `/security` page (LM-112).

### LM-111: Rollout plan that does not block the current deploy
**Owner:** Claude · **Effort (estimate):** 1–2 days

**Why**
Phases 1 and 2 are merged and waiting to deploy. Phase 3 must not hold them up, and the current deploy must not paint Phase 3 into a corner.

**Scope**
- **The current deploy goes ahead unchanged,** in the order in `docs/security/launch-checklist.md` section 2:
  1. all 18 migrations;
  2. edge functions and Lambdas;
  3. the iOS build;
  4. the web app.
  
  LM-105 part 1, the backup with a deadline, is added before step 1.
- **Phase 3 ships behind a per-account flag,** in this order:
  1. schema (LM-92, additive, so plaintext keeps working);
  2. handover Lambdas that accept both modes;
  3. the iOS build with keys, the phrase and on-device jobs, off by default;
  4. internal accounts migrate (LM-106);
  5. everyone else migrates;
  6. retire the server-side text functions and pg_cron jobs.
- **Rollback at each step:** before the migration, turning the flag off restores today's behaviour. After an account migrates, there's no rollback for that account by design (the server can't decrypt), so the flag stays on and fixes go forward.

**Acceptance criteria:** the plan is written into `docs/security/launch-checklist.md` as a new section, and the user has reviewed it.

**Dependencies:** LM-84.

**Out of scope:** dates.

### LM-112: Web app: note ticket (no build)
**Owner:** User · **Effort (estimate):** under 1 day

**Why**
Phase 3 keys live only on iOS devices, so encrypted journals can't be read in a browser. The web app needs its own design before it can show any of them.

**What must be true before any web work**
- A separate design for browser access exists and is approved. Options include a passkey with WebAuthn PRF, a device-to-browser handoff, or read-only access. It would revisit D1.
- Until then, the web app, `/security` included, makes no claim about encrypted storage. It keeps today's wording and its existing rule of going live only after the matching iOS build ships.
- For an account that has migrated (LM-106), the web app shows a plain notice instead of journal content: "This journal is locked to your iPhone." It does not show ciphertext or error states. *This notice is the one web change Phase 3 implies. It is listed here so it isn't forgotten, and it is not ticketed for build.*

**Acceptance criteria:** this note is linked from LM-84's spec and from `docs/privacy-follow-up-tickets.md` LM-74 (web parity).

**Dependencies:** none. **Out of scope:** any web build.

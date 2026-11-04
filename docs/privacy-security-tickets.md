# Privacy and security: tickets

People say raw, personal things to Lumen out loud. These tickets make three claims true and checkable:

- **Nobody nearby can open your journal.**
- **The AI never keeps or learns from your words, and never sees the names of the people you talk about.**
- **We can't read your stored journal.**

They're grouped into three phases. Phase 1 must be finished before any public launch or privacy claim.

| Ticket | Title | Area | Size | Depends on |
|---|---|---|---|---|
| **Phase 1: launch blockers** |||||
| LM-43 | Paid AI tier with zero data retention | Infra + config | S | — |
| LM-44 | Logs never contain journal content | Lambda + CDK | S | — |
| LM-45 | No standing admin access | Process + config | S | — |
| LM-46 | Size caps and validation on every RPC | Supabase | S | — |
| LM-47 | App lock and private previews | Flutter + iOS | M | — |
| LM-48 | Complete deletion: account and session | Supabase + Flutter | M | — |
| LM-49 | Forget a person | Supabase + Flutter | M | LM-48 |
| LM-50 | Off the record sessions | Flutter + Lambda | M | — |
| LM-51 | Auto-forget old transcripts | Supabase + Flutter | S | LM-48 |
| LM-52 | Export my journal | Supabase + Flutter | S | — |
| LM-53 | "Who hears you" screen and security page | Flutter + docs | S | LM-43, LM-44 |
| LM-54 | Penetration test, disclosure and incident plan | Release | M | all Phase 1 |
| **Phase 2: pseudonymization** (gated on the spike, task_c85a425b) |||||
| LM-55 | On-device name swap module | Flutter | M | spike = go |
| LM-56 | Pseudonymize extraction, card and brief calls | Flutter + Lambda | M | LM-55 |
| LM-57 | "What Lumen shared" log | Flutter | S | LM-56 |
| LM-58 | Sign in with Apple and passkeys | Supabase + Flutter | M | — |
| **Phase 3: keys only your devices hold** (needs a design spec first) |||||
| LM-59 | Key management and recovery | Flutter + iOS | L | D1, D2 |
| LM-60 | On-device embeddings and memory search | Flutter | M | LM-59 |
| LM-61 | Encrypt stored content; move graph merging to the device | Flutter + Supabase | L | LM-59, LM-60 |
| LM-62 | Migrate existing journals; devices and key rotation | Flutter + Supabase | M | LM-61 |

**Can start in parallel today:** LM-43, LM-44, LM-45, LM-46, LM-47, LM-50 and LM-52.

**Decisions needed before Phase 3:**
- **D1:** should the web app be able to read journals? If yes, keys are unlocked in the browser with a passkey (WebAuthn PRF).
- **D2:** when a user loses their key, is permanent data loss acceptable, or do we offer optional key escrow, which weakens the claim?

**Rules every ticket follows:**
- No journal content in logs, analytics, crash reports or error messages. That includes transcripts, card text, entity names and audio.
- Writes go only through SECURITY DEFINER RPCs called with the user's token, never with a service key.
- Every new user-owned table joins the deletion test in LM-48.
- Privacy copy says only what is true today. Say "keeps nothing" only after LM-43 is verified, and "we can't read it" only after LM-61 ships.
- **Never commit** `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.

---

## Phase 1: launch blockers

### LM-43: Paid AI tier with zero data retention
**Area:** Infra + config · **Size:** S · **Depends on:** —

Journal audio and text must never be used to train models or be kept by the AI provider. This also ends the free-tier 429s.

**Scope**
- Move the Gemini key behind `echo-insights/gemini-api-key` to a billed project. This covers Live, 2.5 Flash and TTS.
- Check Google's current terms for the paid Gemini API and for Vertex AI. Vertex offers zero data retention: prompt caching off, plus an exemption from abuse-monitoring logs on request.
- If Vertex is needed for zero retention, check that the Live API and ephemeral tokens work there before switching. Otherwise, record the gap.
- Write the result to `docs/security/ai-processing.md`: each provider, what it receives, how long it keeps it, and a link to its terms.

**Done when**
- No call uses free-tier quota.
- The document states the retention terms, with the date each was checked.
- A 10-call burst gets no 429s.

### LM-44: Logs never contain journal content
**Area:** Lambda + CDK · **Size:** S · **Depends on:** —

**Scope**
- Audit every `console.*` call and error path in `infra/lambda/*` and `supabase/functions/*`. Log only IDs, counts, timings and error classes.
- Add a `safeLog` helper and use it everywhere. Model errors are logged by status and class, never by body.
- Set CloudWatch retention to 14 days on every log group, in CDK.
- Add a CI test that runs each handler on a fixture with marker text (`ZZ-SECRET-MARKER`) and fails if the marker appears in captured log output.

**Done when**
- The marker test passes for every Lambda and edge function.
- `cdk diff` shows the retention setting.
- Any exception that's thrown still produces no content in the logs.

### LM-45: No standing admin access
**Area:** Process + config · **Size:** S · **Depends on:** —

This answers the original worry that Supabase admins can read journals. Phase 3 is the full fix; this limits it now.

**Scope**
- Require MFA on the Supabase org, the AWS root and IAM users, and GitHub.
- Keep org members to a minimum. No dashboard SQL against user tables in production.
- Write a break-glass runbook in `docs/security/admin-access.md`: who can get access, how (time-limited, with a stated reason), and where it's logged.
- Use synthetic data in staging and local only. Never copy production rows.
- Rotate the Gemini key and the Supabase service key, and record the dates.

**Done when**
- MFA is enforced in all three consoles (screenshots go in a private note, not the repo).
- The runbook has been reviewed.
- Both keys have been rotated, with the apps and Lambdas still working.

### LM-46: Size caps and validation on every RPC
**Area:** Supabase · **Size:** S · **Depends on:** —

This picks up the deferred findings from LM-37 and LM-38.

**Scope**
- Cap sizes and check types on:
  - `save_session_brief`: audio size and the `focus` and `openingThread` lengths and types;
  - `save_session_card`;
  - the notebook commit RPCs;
  - `retrieve-memory` inputs.
- A null revision raises `22023`, not `23502`.
- Add API Gateway throttling per route, alongside `retrieve_rate_limits`.

**Done when**
- pgTAP tests cover each cap, both just under and just over the limit.
- The deploy passes `db push --dry-run`.

### LM-47: App lock and private previews
**Area:** Flutter + iOS · **Size:** M · **Depends on:** —

The most likely person to read a journal is someone holding the phone.

**Scope**
- Optional Face ID or passcode lock (`local_auth`), checked on launch and after N minutes in the background.
- Blur the app-switcher snapshot whenever the app is locked or showing journal content.
- Notifications never include journal text.
- Ask for Face ID again before export, deletion, turning the lock off, and (later) key recovery.
- Store cached brief audio, drafts and any local files with `NSFileProtectionComplete`.
- Quiet mode: Lumen's voice plays only through headphones while it's on.

**Done when**
- Widget tests cover the lock state machine.
- On the simulator: lock on resume, a blurred switcher, and re-authentication before export.
- The file-protection class is verified on the cached audio.

### LM-48: Complete deletion: account and session
**Area:** Supabase + Flutter · **Size:** M · **Depends on:** —

**Scope**
- Extend the account deletion in `20260922000000_account_deletion.sql` to every newer table: `session_briefs`, `session_cards` (including drafts), `follow_ups`, `asked_questions`, `entity_embeddings`, `conversation_runtime_*` and any storage objects.
- Add a "Delete this session" action on the card and in the notebook menu. It removes turns, the card, the brief if it came from that notebook, and graph contributions that no other notebook backs up.
- **Guard test:** a pgTAP test lists every `public` table with a `user_id` (or one owned through a notebook) and fails if deletion leaves a row in any of them.

**Done when**
- The guard test passes, and it fails when a new user-owned table is added without deletion support.
- On the simulator, deleting a session leaves no trace on the dashboard or in the graph.

### LM-49: Forget a person
**Area:** Supabase + Flutter · **Size:** M · **Depends on:** LM-48

**Scope**
- Add "Forget [name]" on an entity's page. It deletes the entity, its relations, embeddings, follow-ups and asked questions, and adds an `entity_suppressions` row so extraction doesn't recreate it.
- Find cards and briefs that mention the person. Delete the current brief if it does, and mark those cards for regeneration, or redact them where regenerating isn't possible.
- Show a confirmation screen listing what will be removed.

**Done when**
- pgTAP covers the cascade and the suppression.
- A later session that mentions the name doesn't bring the entity back.

### LM-50: Off the record sessions
**Area:** Flutter + Lambda · **Size:** M · **Depends on:** —

**Scope**
- An "Off the record" toggle on the session screen, chosen before starting or at any time during the session.
- While it's on:
  - no turn commits, no extraction, no card drafts or final card, no brief;
  - nothing is cached on the device;
  - Gemini Live still runs, under LM-43's retention terms.
- A clear visual state so the user always knows it's on.
- Turning it on mid-session keeps what was saved before; the UI says so.

**Done when**
- Integration tests show zero write RPCs during an off-the-record session.
- The dashboard shows no notebook, or a "nothing saved" entry if we choose to keep one.

### LM-51: Auto-forget old transcripts
**Area:** Supabase + Flutter · **Size:** S · **Depends on:** LM-48

**Scope**
- A user setting: keep transcripts forever, or for 90, 30 or 7 days. Cards and the graph stay.
- A `pg_cron` job deletes `conversation_turns` and `journal_entries` older than the user's setting.
- Offer the setting once, after the third session.

**Done when**
- pgTAP covers deletion at the boundary and checks that cards and entities survive.
- The cron job is visible in the migration.

### LM-52: Export my journal
**Area:** Supabase + Flutter · **Size:** S · **Depends on:** —

**Scope**
- An `export_my_data()` RPC returns notebooks, turns, cards, entities and relations as JSON. The app also renders a Markdown version and shares it through the iOS share sheet.
- Asks for Face ID again first (LM-47).

**Done when**
- The export round-trips in a test.
- No other user's data appears in it (pgTAP).

### LM-53: "Who hears you" screen and security page
**Area:** Flutter + docs · **Size:** S · **Depends on:** LM-43, LM-44

**Scope**
- One plain screen, shown on the first mic tap and reachable from settings, listing each party and what it sees. It says only what's true now and updates as Phases 2 and 3 ship.
- A public security page listing these controls in plain words.
- Add `/.well-known/security.txt` on the web domain.

**Done when**
- Every sentence on the screen and the page can be traced to a shipped ticket.
- Copy reviewed against the rules above.

### LM-54: Penetration test, disclosure and incident plan
**Area:** Release · **Size:** M · **Depends on:** all Phase 1

**Scope**
- An external penetration test of the app, API Gateway, Lambdas and Supabase RLS, then fix or accept each finding.
- A vulnerability-disclosure page.
- `docs/security/incident-response.md`: severity levels, who does what, and user notification within 72 hours (GDPR).
- Alerts on unusual access: an admin session, a bulk read, or an auth-error spike (CloudTrail and Supabase logs).

**Done when**
- The penetration test report has no open Critical or High findings.
- The alerts fire in a test.

---

## Phase 2: pseudonymization

Gated on the spike (task_c85a425b). Extend the spike to compare plain tags, tags that carry a role, and consistent fake names, on misspelled transcripts.

### LM-55: On-device name swap module
**Area:** Flutter · **Size:** M · **Depends on:** spike = go

**Scope**
- `PseudonymMap` built from the user's entity graph:
  - each entity has aliases;
  - fuzzy matching on spelling and sound ("Pria" → "Priya");
  - a list of names that are also words (Will, June, Rose…), replaced only when the graph knows them as a person.
- Detect new names with on-device name recognition (Apple NaturalLanguage).
- Replace only private identifiers: people, addresses, employers, small towns. Keep public entities.
- Swap back with a check that the round trip restores the original text.
- The map is stored encrypted on the device (Keychain-protected), never on the server.

**Done when**
- Unit tests cover aliases, misspellings, names that are also words, new names, and the round trip.
- Matching quality is at least what the spike's "go" required.

### LM-56: Pseudonymize extraction, card and brief calls
**Area:** Flutter + Lambda · **Size:** M · **Depends on:** LM-55

**Scope**
- Text sent to extract-graph, close-session (card and drafts) and session-brief carries placeholders. The `EXISTING ENTITIES` and `RECENT CONVERSATION` context uses the same placeholders.
- Results are swapped back on the device before they're saved or shown.
- Brief audio: either generate the opener audio on the device from the swapped-back text, or document that TTS receives the real name. Choose in the ticket and update LM-53's copy to match.
- Voice to Gemini Live is out of scope; LM-53 says so.

**Done when**
- The marker test (LM-44 style) shows no known entity name reaches any Lambda request body.
- Extraction precision and recall on the spike fixtures stays within the agreed tolerance.

### LM-57: "What Lumen shared" log
**Area:** Flutter · **Size:** S · **Depends on:** LM-56

**Scope**
- An on-device log, viewable per session, of each pseudonymized request sent to the AI. It's kept locally for 7 days and never uploaded.

**Done when**
- The log shows the exact text that was sent.
- The log is deleted along with the session.

### LM-58: Sign in with Apple and passkeys
**Area:** Supabase + Flutter · **Size:** M · **Depends on:** —

**Scope**
- Sign in with Apple, and passkeys, through Supabase Auth.
- A device list with remote sign-out.

**Done when**
- New and existing accounts can link either method.
- Signing out a device remotely revokes its refresh token.

---

## Phase 3: keys only your devices hold

Write a design spec first: `docs/superpowers/specs/<date>-zero-access-journal-design.md`. It needs D1 and D2 settled.

### LM-59: Key management and recovery
**Area:** Flutter + iOS · **Size:** L · **Depends on:** D1, D2

- A master key in the Keychain, protected by the Secure Enclave, and per-notebook keys wrapped by it.
- Sync across the user's devices through iCloud Keychain.
- A recovery phrase, plus optional escrow if D2 allows it.
- Web unlock with a passkey if D1 is yes.
- Encrypt with AES-GCM, using an audited library. No custom cryptography.

### LM-60: On-device embeddings and memory search
**Area:** Flutter · **Size:** M · **Depends on:** LM-59

- Run gte-small on the device. Embeddings are stored encrypted, and search is brute force on the device.
- Remove `retrieve-memory`'s server-side use of vectors.

### LM-61: Encrypt stored content; move graph merging to the device
**Area:** Flutter + Supabase · **Size:** L · **Depends on:** LM-59, LM-60

- Turns, cards, briefs, entity names and relation labels are stored as ciphertext.
- Graph merging (today's `_commit_apply_turn`) moves to the device. The server keeps only IDs, revisions and ciphertext.
- Lambdas receive plain text over TLS only to process it, and the device encrypts what comes back.

### LM-62: Migrate existing journals; devices and key rotation
**Area:** Flutter + Supabase · **Size:** M · **Depends on:** LM-61

- A one-time migration on the device: download, encrypt, upload, then delete the plain text on the server.
- Adding and removing devices, and re-wrapping keys when a device is revoked.
- Copy changes to "we can't read it" only after the migration completes for that account.

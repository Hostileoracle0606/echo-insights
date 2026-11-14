# Privacy and security: follow-up tickets

Phase 1 (LM-43 to LM-54) and Phase 2 (LM-55 to LM-58, LM-63) are built and integrated on `chore/phase2-integration` (head 787a44f at the time of writing). Nothing is deployed or pushed. This document collects every finding that is still open after the reviews, so none of them live only in the SDD ledger.

These tickets follow `docs/privacy-security-tickets.md` and continue its numbering at **LM-64**. LM-59 to LM-62 are Phase 3 (keys only your devices hold). They are already ticketed in that file and are not repeated here. **Phase 3 cannot start until decisions D1 and D2 are made** (see "Decisions waiting on the user"), and it needs its design spec first.

How this was built:

- Sources: the SDD ledger (`progress.md`), `final-review-findings.md`, `phase2-final-findings.md`, `memory-recall-report.md`, the task reports, `docs/security/launch-checklist.md` and `docs/privacy-security-tickets.md`.
- Anything the ledger or a later report marks as fixed is left out (for example: the reconnect and mic-in-error leaks, the U+0001 and 4+ word name redaction bugs, BUG-2/3/4/5/7 from the recall report, the I1 to I3 and M1 to M7 items of the Phase 2 final review, R31). The last section lists what was skipped as already fixed.
- Where a source is unclear, the ticket says so under "Unclear".
- Rulings (R1 to R32) and "BUG-n" / "FINDING-6" names are those used in the ledger and `memory-recall-report.md`. "Task NN" means `task-NN-report.md` or the ledger lines for that ticket.

| Ticket | Title | Area | Size | Priority |
|---|---|---|---|---|
| LM-64 | In-app account deletion and Apple token revocation | Supabase + Flutter + server | L | Launch blocker |
| LM-65 | Device verification pass | Flutter + iOS (manual) | M | Launch blocker |
| LM-66 | Staging check before `deviceList` ships | Supabase + docs | S | Launch blocker |
| LM-67 | Delete the legacy `extract-graph` (Groq) function | Supabase functions | S | Launch blocker |
| LM-68 | Close the Phase 1 console actions and user checks | Process + config | M | Launch blocker |
| LM-69 | Name-swap quality | Flutter | M | Before GA |
| LM-70 | Non-Latin names and one slug rule across Dart, TS and SQL | Flutter + TS + Supabase | M | Before GA |
| LM-71 | Name matcher scaling on long sessions | Supabase + Lambda | M | Before GA |
| LM-72 | Forget: remaining coverage gaps | Supabase + Flutter | M | Before GA |
| LM-73 | Gemini Live: the voice path, the live echo, resumption | Flutter | M | Before GA |
| LM-74 | Web app parity | Web | L | Before GA |
| LM-75 | Per-user rate limits and speak-token reuse | CDK + Lambda | M | Before GA |
| LM-76 | Data-model edges | Supabase | M | Before GA |
| LM-77 | UX: failure and fallback states | Flutter | S | Before GA |
| LM-78 | Phase 2 residual minors | Flutter | S | Before GA |
| LM-79 | Sign-in and passkey follow-ups | Flutter + Supabase | S | Later |
| LM-80 | App lock and file protection hardening | Flutter + iOS | S | Later |
| LM-81 | Alerts, secret migration and security-page links | CDK + process | S | Before GA |
| LM-82 | Privacy copy review | Flutter + web | S | Before GA |
| LM-83 | Test and CI hygiene | Tests + CI | M | Later |

---

## Launch blockers

These are the items that stop a public release. Each has a full ticket below.

1. **LM-64: In-app account deletion and Apple token revocation.** App Store Review Guideline 5.1.1(v) requires an app that creates accounts to let people delete them inside the app. Only the database cascade exists today. With Sign in with Apple, deleting the account must also revoke the Apple token.
2. **LM-65: Device verification pass.** Face ID lock, privacy cover, file protection classes, the share sheet, the R31 reinstall wipe, the mic indicator in the error state, and the Apple and passkey flows. None of these could be proven on the simulator.
3. **LM-66: Staging check before `deviceList` ships.** The device-list claim is held back (ruling R30) until two hosted facts are checked.
4. **LM-67: Delete the legacy `extract-graph` (Groq) edge function.** It has no callers and no forget redaction, so leaving it deployed is a way around LM-63.
5. **LM-68: Close the Phase 1 console actions and user checks.** Billing, MFA, key rotation, the penetration test and the other steps that agents were not allowed to do (ruling R1). This is my classification: the LM-43, LM-45 and LM-54 done-when lines are not met until they are done. See "Unclear" in that ticket.

Deploy order, migrations and the other user actions stay in `docs/security/launch-checklist.md`. This document does not duplicate them.

## Decisions waiting on the user

No work on the tickets named here should start until the decision is made.

1. **FINDING-6: new notebooks start without a cross-session summary.** `get_notebook_snapshot` and extraction retrieval are per notebook, and nothing in `lib` calls `get_user_graph`. A new session's `[graph summary]` and extraction "EXISTING ENTITIES" are empty, so people from older sessions reach it only through the live `get_relevant_memory` tool or by exact slug coincidence ("Priya" alone creates a separate entity). The spec's "extraction context recalls earlier people" holds only for a continued notebook. Decide: accept it, or add an account-wide summary to the first turn of a new notebook. An account-wide summary has privacy consequences, because it feeds more of the graph to Gemini and to the name map. It also touches LM-69, LM-72 and LM-76. The test for it is skipped in `test/memory_recall_scenarios_test.dart`. Source: recall report FINDING-6; ledger R27.
2. **Phase 3 D1: should the web app be able to read journals?** If yes, keys are unlocked in the browser with a passkey (WebAuthn PRF). Source: `docs/privacy-security-tickets.md`. Blocks LM-59 to LM-62.
3. **Phase 3 D2: is permanent data loss acceptable when a user loses their key, or do we offer optional key escrow?** Escrow weakens the "we can't read it" claim. Source: same file. Blocks LM-59 to LM-62.
4. **Ship the passkey beta or not.** Passkeys are built behind `--dart-define=PASSKEYS_ENABLED=true` and are off by default. They depend on Supabase's passkey beta (announced 2026-05-28; the API may change without notice, and the task report relays community reports of registration errors it did not verify), on a relying-party domain only you can choose, an `apple-app-site-association` file and the Associated Domains entitlement. Decide whether a beta is acceptable for production. If yes, see LM-79. Source: Task 58; launch-checklist section 9.
5. **Vertex zero data retention vs. the current paid-API claim.** Ruling R13: the paid Gemini API has no documented zero-retention mode, so "keeps nothing" is not claimed. Vertex AI could provide it (prompt caching off and a written abuse-monitoring exemption), but Task 43 found it is not drop-in: ephemeral tokens are not documented there and the live model was missing. The ledger recommends staying on the paid Gemini API. Decide: stay on the paid API with today's wording, or plan a Vertex migration (which would be its own ticket), or get Google's written confirmation on the four questions in `docs/security/ai-processing.md` section 4. Source: Task 43; R13; `ai-processing.md` sections 5 and 6.
6. **Unclear, needs your confirmation: opt-in erase of a forgotten name from saved transcripts.** The ledger records a user decision (BUG-2, 2026-11-11) and ruling R27: Lumen never reads a forgotten person, and your own transcript text is kept verbatim for you to read. LM-63 did this with a redacted copy (`context_text`). A separate worktree report, `forget-transcripts-report.md` (branch `feat/forget-transcripts`, migrations `20261110000000` and `20261110000100`, not in `chore/phase2-integration`), builds a different version of this with an opt-in "also replace their name in my saved transcripts" switch. The ledger never mentions that branch, so its status is unknown. Decide whether the opt-in erase is wanted; if yes it needs its own ticket and a merge against LM-63.

---

## Launch blocker tickets

### LM-64: In-app account deletion and Apple token revocation
**Area:** Supabase + Flutter + server · **Size:** L · **Priority:** Launch blocker

App Store Review Guideline 5.1.1(v) says an app that lets people create an account must let them delete it inside the app. Lumen has "Delete this session" and "Forget a person", and the database already cascades on account deletion (`20260922000000_account_deletion.sql`, extended by LM-48), but there is no "Delete my account" control and nothing calls the cascade. Because LM-58 added Sign in with Apple, deleting the account must also revoke the Apple token through Apple's REST API. That needs a Sign in with Apple key and a server-side call, which no ticket has built. The two must ship together.

**Scope**
- A "Delete my account" action in the privacy sheet, behind `requireReauth`, with a confirmation screen that says what is removed and that it cannot be undone.
- A server path that runs the existing deletion cascade for the caller only, then removes the auth user. Use a SECURITY DEFINER RPC or a function that uses the user's own token; per the global rules, not a service key in the client.
- Apple token revocation (`/auth/revoke`) for users who signed in with Apple. This needs the Sign in with Apple key held server-side (a secret, never in the repo) and the user's Apple refresh or authorization token. Check what Supabase Auth keeps for the Apple identity before choosing where this call runs; the sources do not say.
- After deletion, run the signed-out cleanup (name map, forgotten hashes, shared log, held brief) and return to login.
- Extend the LM-48 guard test so a new user-owned table without deletion support still fails it, and make sure the new path covers `entity_suppressions`, `suppression_keys`, device sessions and anything LM-55 to LM-63 added.
- Update `docs/security/launch-checklist.md` (section 1 already lists both as blockers) and the privacy copy.

**Done when**
- On a device, an email account and an Apple account can each delete themselves in the app, and the Apple token is revoked (verify in Apple ID settings that the app no longer appears).
- pgTAP shows no row left for the deleted user in any user-owned table, and a second user is untouched.
- A failed re-auth or failed revocation does not leave a half-deleted account (decide and test the order: revoke first, or delete first and retry revocation).

**Unclear:** the sources say only that revocation "needs a Sign in with Apple key and a server-side call". The exact token to send to Apple is not established.

**Source:** ledger "Follow-up (needs a ticket): in-app account deletion UI" (after the Final review); Task 58 minor "Apple token revocation on account deletion (App Store 5.1.1(v)) missing from checklist"; `phase2-final-findings.md` M6; launch-checklist section 1.

### LM-65: Device verification pass
**Area:** Flutter + iOS (manual test) · **Size:** M · **Priority:** Launch blocker

Many Phase 1 and 2 controls were verified only by widget tests, fakes or by reading Swift code. The simulator has no enrolled Face ID, no Apple ID and no real share targets. Each item below was reported as "unverified on device" by a reviewer or implementer. Do this pass once, on a real iPhone, on a build with the full migration set applied to staging, and record the results.

**Scope**
- **Face ID lock (LM-47):**
  - lock on resume with no flash of content (the native cover held until Dart releases it, R11 and the round-2 fix);
  - the grace period, and what happens when the app is backgrounded during the Face ID sheet;
  - turning the lock off asks for re-auth;
  - re-auth before export, "Delete this session", forget a person, and shortening retention;
  - the Swift hold and timeout logic, which was verified by reading only.
- **Privacy cover:** a blank blurred switcher card whenever the app is locked or shows journal content. Note that `makeOpaque` hard-codes the paper colour.
- **File protection classes:** read the class back on a real file. The journal uses `CompleteUnlessOpen` (not `Complete`) so a turn can be written while locked; confirm that files created while locked inherit the directory class, and check the `.tmp` file class and the cached brief audio. Check that the device build signs with the Data Protection capability in the provisioning profile.
- **Share sheet:** the real iOS share sheet and AirDrop for export. The export zip may linger in temp up to an hour, so copy must not say "deleted immediately".
- **R31 reinstall:** sign in, forget a person, delete the app, reinstall. The name map and forgotten hashes are gone, the app lock is off, and the first launch after that wipes nothing. A build from before this change loses its app-lock setting once.
- **Mic indicator in the error state (cbd5377):** the unit test shows `stop()` is called when the session fails; confirm on a device that the orange mic indicator clears.
- **Off the record and reconnect:** go off the record, say something, come back on, and check Lumen does not refer to it. The reconnect is only tested with a fake socket and has never run against real Gemini.
- **Sign in with Apple:** a new Apple account (the intro plays), an existing email account (same email auto-links; a hidden email creates a separate account to link from Privacy), cancel the sheet, revoke the app in iOS Settings and sign in again (the name arrives once only).
- **Passkeys** (only if the decision is yes): add, sign out, sign in with it, cancel, and one account with both an email and a passkey.
- **Cross-device forget (I2):** forget on phone A, bring phone B to the foreground. Its shared log is empty, the held brief is not used, the name map lacks the person. With B offline, its held brief must not play.
- **Sign out of this phone:** a hidden-email Apple account can sign out and back in with the real account.
- **NLTagger name recognition:** how well it finds new names on a device, including non-Latin names (only the Dart side and the build were tested).

**Done when**
- Every line above has a dated pass or a filed defect. The checklist (sections 6 and 9) is updated with the results.

**Source:** ledger Tasks 47 (minors; "needs a real device test"), 52, 55 (NLTagger), 58; "Mic fix" lines (iOS indicator unverified); Residual re-review ("Device-owed: R31 reinstall test"); `task-integration-report.md` concerns; launch-checklist sections 6 and 9.

### LM-66: Staging check before `deviceList` ships
**Area:** Supabase + docs · **Size:** S · **Priority:** Launch blocker

Ruling R30 removed `PrivacyFeature.deviceList` from `shipped` and its line from `/security`, because the claim depends on two hosted facts nobody has checked. The device list itself still shows in the app; only the public claim is held. Until the check passes, the claim stays off.

**Scope**
- On staging, run `select has_table_privilege('postgres', 'auth.sessions', 'DELETE')`. It must return true.
- As the `authenticated` role, call `revoke_my_session` on a second session. It must return true and the row must be gone.
- Confirm the JWT expiry setting is 3600 seconds or less (Authentication, Sessions / JWT settings). A signed-out device keeps working until its access token expires, up to an hour.
- Confirm no Supabase setting (time-box, inactivity timeout, single session per user) conflicts with what the list shows.
- Post-migration check: sign in on two simulators, sign one out from the other, and confirm the first fails to refresh. Confirm `select * from auth.sessions` is still unreadable to `authenticated`.
- If both facts hold: add `deviceList` to `shipped` in `lib/privacy/privacy_claims.dart` and its line back to `IPHONE_CONTROLS` in `src/routes/security.tsx` (text from `gatedClaims[PrivacyFeature.deviceList]`). Ship the iOS build first, then the web page. If either fails, leave the flag off and change the copy.

**Done when**
- The results are recorded in the checklist, and `test/privacy_copy_test.dart` passes with the flag flipped (it fails if the app and web copy drift).

**Source:** ledger R30; Task 58 ("User/staging check: has_table_privilege('postgres','auth.sessions','DELETE') on hosted"); `phase2-final-findings.md` I3; launch-checklist sections 7 and 9.

### LM-67: Delete the legacy `extract-graph` (Groq) edge function
**Area:** Supabase functions · **Size:** S · **Priority:** Launch blocker

`supabase/functions/extract-graph/` sends conversation text to Groq. Nothing in the app calls it (the app uses the runtime's extraction route), and it has no forget redaction, so while it is deployed it is a path around LM-63. The Phase 2 final review made deleting it, not redeploying it, a firm checklist step.

**Scope**
- Delete the deployed function (`supabase functions delete extract-graph --project-ref ...`, staging first) and remove `supabase/functions/extract-graph/` from the repo, with any CI step, test or doc that names it.
- Remove the Groq secret from the project, and note the removal in `docs/security/ai-processing.md` (the Groq row and finding F1).
- Check that no web or Flutter caller exists. The reports say there is none in-repo; confirm against the deployed function's invocation logs (before deleting) in case something outside this repo calls it.
- Decide about `speak-agent` (ElevenLabs) in LM-74.

**Done when**
- The function is gone from both projects and the repo, `ai-processing.md` and the launch checklist reflect that, and the CI suites still pass.

**Source:** ledger Task 43 follow-up (F1); Task 63 minor "legacy Groq edge function extract-graph has no forget redaction (make deletion a firm checklist step)"; `phase2-final-findings.md` M6; launch-checklist section 2 step 2.

### LM-68: Close the Phase 1 console actions and user checks
**Area:** Process + config · **Size:** M · **Priority:** Launch blocker

Under ruling R1 the agents wrote only the repo-side parts of LM-43, LM-45 and LM-54. The console, billing, MFA, key rotation and test steps stayed with the user, so those tickets' done-when lines are still unmet. The detailed steps are already in `docs/security/launch-checklist.md` sections 1 to 5; this ticket tracks that they are done and recorded.

**Scope**
- **Before anything ships:** read the first GitHub run of `.github/workflows/privacy-tests.yml` (it has never run on GitHub; see LM-83 for what to look for).
- **Billing (LM-43):** enable billing on the Google Cloud project behind `echo-insights/gemini-api-key` and the one behind `VITE_GEMINI_API_KEY` (or retire the latter, LM-74); turn AI Studio project logging off; run the 10-call burst with no 429s; ask Google Cloud support the four questions in `ai-processing.md` section 4; then flip `paidTierVerified` in `lib/privacy/privacy_claims.dart`. Do not claim "keeps nothing".
- **Access (LM-45):** MFA on Supabase, AWS root and IAM users, and GitHub; minimal org members; confirm `vars.SUPABASE_PROJECT_REF` in the `staging` GitHub environment is a staging project and the access token cannot reach production (the workflow checks the URL matches the ref, not that it is staging); rotate the Gemini key, then the Supabase credentials (read the legacy-key outage warning first), the production DB password and the personal access token; name a legal or privacy adviser.
- **Log groups (LM-44):** after `cdk deploy`, delete the old auto-created `/aws/lambda/*` log groups (never expire, may hold old content).
- **Alerts (LM-54):** pass `-c alertEmail=...`, confirm the SNS subscription, fire each alarm once on purpose in staging, set a Gemini usage budget alert, enable GitHub private vulnerability reporting, check whether the Supabase plan has audit logs or log drains, check for an existing CloudTrail trail before deploying a second one.
- **Penetration test (LM-54):** book a firm, give them `pentest-scope.md`, a staging project and synthetic accounts, and fix or accept each finding.

**Done when**
- The LM-43, LM-45 and LM-54 done-when lines are met and dated in a private note (not the repo), with no open Critical or High pen-test finding.

**Unclear:** whether the penetration test and the other console steps count as launch blockers is not stated in the sources; the checklist lists them as user actions in order but marks only account deletion and Apple revocation as blockers. I have classed them as blockers because the original LM-54 done-when requires a clean pen test. Change the priority if you disagree.

**Source:** ledger R1; Tasks 43, 44 (deploy follow-up, CI), 45 (user check on the CI target), 54 (user steps), 53 (flip flags); launch-checklist sections 1 to 5.

---

## Before GA and later tickets

### LM-69: Name-swap quality
**Area:** Flutter · **Size:** M · **Priority:** Before GA

The LM-55 name swap passed the spike's criteria and the LM-56 measurement through the real path (entity precision 33/43, recall 33/35, relations 18/25; 0 leaks). Several known quality gaps were accepted at the time. They affect what leaks to Gemini and how well extraction works, so they should be measured and reduced.

**Scope**
- **Cached turns use canonical names, not the user's spelling.** Matters for the LM-36 quote modes, where a quoted turn would show the graph's spelling instead of what was said.
- **Word lists** (common-word and public-entity lists) are small and bundled; the false-positive rate on a real graph is unknown. Grow them and test against real-graph data.
- **Sentence-initial names:** "Will you…" or "Mark you…" addressed to a person that stays unswapped. Decide the trade-off (swap and risk garbling an ordinary word, or leave it).
- **Smaller known limitations:** "Mark and Hill" share one fake name; an invented surname corrupts rehydrate; `composeLatin` covers only table pairs; non-Latin misspellings do not fuzzy-match; exotic Unicode (fullwidth, zero-width characters) leaks.
- **Performance:** the name recognizer runs once per swapped piece over the platform channel (about 70 short strings of context per extraction), and device timings were never measured. Re-measure on a device (LM-65). Also, Task 56's note says the cache is rescanned on the UI isolate on each map change. The Phase 2 final fix addressed the equivalent scan for the forget redactor (M2), but it is unclear whether the pseudonym cache scan was also changed; check before working on it.
- Re-run the precision and recall measurement after each change.

**Done when**
- Each item is either fixed with a test or recorded as accepted with the reason. The extraction precision and recall on the spike fixtures stay within the tolerance LM-56 passed.

**Source:** ledger Task 55 minors and fix-round notes; Task 56 minors ("cached turns use canonical names...", "UI-isolate scan of cache on each map change"); Task 56 report (recognizer channel timing).

### LM-70: Non-Latin names and one slug rule across Dart, TS and SQL
**Area:** Flutter + TS + Supabase · **Size:** M · **Priority:** Before GA

The Dart, TypeScript and SQL slug functions give different ids for some names. The residual fix (R3) made the commit check the incoming name's slug against suppressions, so a forgotten person is not recreated as a readable id. That is a patch over the divergence; it does not remove it. Separately, the app's noise filter drops entities whose names have no Latin letters, so those people never enter the graph.

**Scope**
- **One rule.** Dart differs from SQL on й, Greek accents, Hangul and voiced kana; TS differs on voiced kana. Choose one Unicode-preserving rule, implement it in all three, and backfill existing ids if needed. Correct the "same rule" comments. Use shared test vectors (андрей, nguy-n, 김민수, प्रिया, 李雷, Иван).
- **Device and server hash sets differ** for some scripts (LM-63 concern). Once the rule is shared, verify they agree.
- **`filterNoise` drops non-Latin names.** This was found by the LM-56 measurement and is pre-existing. Fix it so non-Latin people can enter the graph, then make sure forget, the name swap and the redactors handle them.
- **Non-ASCII hyphens in names** miss the matcher.
- **`remove_entity` slug rule is one-directional across clients,** and the report on it overclaimed. State the real behaviour and fix or document it.
- **A person created under two ids** (for example, by a web client and the app) is not fully forgotten for a user with both clients.

**Done when**
- The same name gives the same id in Dart, TS and SQL (a shared test table proves it), a non-Latin name survives the noise filter and can be forgotten, and the "same rule" comments are true.

**Source:** ledger "Minor (deferred)" after Phase 1 residual re-review (non-ASCII hyphens, `remove_entity` slug rule, a person under two ids); Final fix re-review NB2 and R3; Task 56 ("Pre-existing: app noise filter drops non-Latin names (needs ticket)"); Task 63 concern 1.

### LM-71: Name matcher scaling on long sessions
**Area:** Supabase + Lambda · **Size:** M · **Priority:** Before GA

The server-side redaction matcher scales about quadratically with text length. A 97 KB transcript with a 4-word forgotten name took about 11 s locally, above the 8 s Lambda timeout, so close-session returns 503 and the card does not generate. No name leaks (it fails closed), but a long session after a forget would stay without a card. The ledger says to revisit with real timings.

**Scope**
- Measure the matcher with real-size transcripts and several forgotten names, locally and on staging.
- Make it linear, or bound the work (for example, only scan windows near candidate tokens), and keep the 2 MB input cap.
- Re-time the LM-63 backfill, which took about 4.2 s per 20,000 turns locally and holds row locks until commit. Decide whether to batch it for large accounts.
- Check the preview counts and the redaction results stay identical.

**Done when**
- A 100 KB transcript with several forgotten names redacts well inside the Lambda timeout, with the same output as before, and a long-session test exists.

**Source:** ledger "Minor (deferred)" (matcher scales ~quadratically); Task 63 concerns and minor (backfill holds row locks); Phase 1 "Follow-ups: matcher timing on long sessions".

### LM-72: Forget: remaining coverage gaps
**Area:** Supabase + Flutter · **Size:** M · **Priority:** Before GA

Forget now covers the graph, cards, briefs, follow-ups, embeddings, retrieval, resume context and the extraction path (LM-49, LM-63). The user decision (BUG-2) is that a forgotten person is never brought up or shown. These gaps remain, and each one can let a name back in. Several are documented design limits; decide per item whether to fix or accept.

**Scope**
- **Lowercase single-word names** are not caught (the C1 rule, which avoids corrupting ordinary words). If speech-to-text writes "priya", it stays, including in follow-ups. Forgetting "Will" also drops questions that start with "Will" (R19, accepted).
- **Nicknames and first names alone:** forgetting "Maya Chen" does not catch "Maya", and a later "Maya" creates a new entity. The copy says so. Consider asking the user for aliases on Forget.
- **Matcher limits:** `Priya\nRaman`, `priya_raman` and nicknames are missed; "Maya. Chen" across a sentence boundary over-redacts (privacy-safe).
- **Metadata key collision:** a value can be lost if a metadata key names the forgotten person.
- **Dead rows:** old slugs persist in dead tuples, WAL and backups until vacuum or expiry (the HMAC key lives in the same database as the hashes, so it protects against table-only leaks, not a full dump).
- **`conversation_runtime_inbox` `observation` and `document`** can hold transcript text and names, and neither forget nor auto-forget touches them. No client uses that route today; either clean it or remove it.
- **Names learned from speech** (never in the graph) are not pruned from the name map when another device forgets.
- **Brief handler** sent other entities and follow-up text unredacted in the LM-49 version; LM-56 superseded that path, but confirm no path remains.
- **Lambda tests** use stubs that do not exercise the SQL tokenizer; add an end-to-end redaction test against a local database.

**Done when**
- Each item is fixed with a test or accepted in `docs/security/` with a user-facing sentence where it affects the promise.

**Source:** ledger R19; "Minor (deferred)" after Phase 1 residual re-review; Task 49 minors (HMAC key, dead tuples, Lambda stubs, "Maya. Chen"); Task 56 note on v2 redaction; Task 63 concerns; recall report observations; `task-integration-report.md` concerns 2 and 3; Phase 2 integration report (I2 note on speech-learned names).

### LM-73: Gemini Live: the voice path, the live echo, resumption
**Area:** Flutter · **Size:** M · **Priority:** Before GA

Ruling R24(d) kept the Gemini Live voice path unchanged: the microphone audio and Lumen's live conversation go to Gemini with real names, and "Who hears you" says so. The pseudonymization covers extraction, cards, drafts and briefs only. Related gaps in the live path were found during Forget work.

**Scope**
- **Voice path not swapped.** Decide whether the live system instruction and tool results can carry stand-in names (the audio itself still carries real names). If not, make sure the copy keeps saying so. This ties to decision 5 (Vertex).
- **The live echo of a forgotten name.** A turn that names a forgotten person still reaches Gemini Live in the live exchange. Everything saved or re-sent afterwards is redacted, so the name can come up in that exchange only. Decide whether to filter or reconnect after a forget.
- **Forgetting during a live session** leaves the name in that session's Gemini context until it ends.
- **Re-seed on reconnect:** this run's unsaved turns are redacted on the device only; check that the redaction works after an app restart (the device knows no forgotten names then and relies on the server).
- **Session resumption is on** (`session_resumption` in `gemini_live_client.dart`). Decide whether to keep it. It keeps server-side context, which is why the off-the-record fix reconnects with a fresh setup. Document the retention effect, and see whether Vertex or the paid API changes the answer.
- **The reconnect has only been tested with a fake socket.** It relies on the token starting a connection and on `client_content` being read on a fresh setup. Verify it against real Gemini (see LM-65).
- **In-progress turn dropped on failure:** when the session fails, the turn being assembled is dropped, not saved (cbd5377). Decide whether to save it.

**Done when**
- Each item is fixed, or stated plainly in the "Who hears you" screen and on `/security`, and the reconnect is verified against real Gemini.

**Source:** ledger R24(d); Task 43 follow-up (session resumption on, F4); Task 63 concerns ("The live echo...", "Gemini Live re-seed of this run's unsaved turns redacted on device only"); `task-integration-report.md` concerns 4 and 5 (final fix wave); "Mic fix" minors.

### LM-74: Web app parity
**Area:** Web · **Size:** L · **Priority:** Before GA

The privacy controls are iPhone-only (that is why `/security` lists iPhone-only lines and is deployed after the iOS release). The web app still has paths that conflict with them.

**Scope**
- **Browser-held Gemini key.** `src/lib/extract-graph.ts` calls Gemini from the browser with `VITE_GEMINI_API_KEY`, which is in the client bundle. Move web extraction to the same runtime route the app uses, and delete the key, or retire this path.
- **ElevenLabs direct path.** `src/lib/agent-voice.ts` posts text straight to `api.elevenlabs.io` with `VITE_ELEVENLABS_API_KEY` when set, bypassing `speak-agent`. Remove the direct path. Decide whether `speak-agent` (the supabase function) and ElevenLabs stay or go, and update `ai-processing.md` (finding F2) and the secrets.
- **Web extraction is not pseudonymized.** Web extraction still sends real names (the LM-56 copy is scoped to iPhone). Either port the name swap, or keep the copy scoped and state it.
- **Web sign-out and device list.** `signOut` appears in `src/routes/__root.tsx`; I did not check what UI it has. There is no device list on the web (LM-58 is Flutter only). Decide whether the web needs either, and whether the web slug rule matches (see LM-70).
- **Web Gemini Live client** mints tokens from the same Lambda, so it has the same voice-path behaviour as LM-73.
- Make sure the web forget path (if any) uses the same server redaction.

**Done when**
- No provider key is in the web bundle, `ai-processing.md` and `/security` describe the web app accurately, and the web either matches the app's controls or says plainly it does not.

**Unclear:** the sources do not say whether the web app should get the controls or stay a limited client. That is a product decision folded into this ticket; split the ticket if you want to port the controls.

**Source:** ledger Task 43 findings F2, F3 and follow-up; Task 56 minor (web extraction still sends real names); `ai-processing.md` section 1; Phase 2 integration report (no in-app sign-out); launch-checklist section 8.

### LM-75: Per-user rate limits and speak-token reuse
**Area:** CDK + Lambda · **Size:** M · **Priority:** Before GA

The LM-46 throttles are API Gateway limits per route, and they are account-wide, not per user (ruling R8 kept the stage default at 10/20 and put 20/40 on the five model-backed routes). One user can use up the throttle for everyone, and a model-backed route has no per-user cost cap.

**Scope**
- A per-user limit on the model-backed routes, including `close-session` (card, draft, brief), `extract-graph` and `live-session`. `retrieve-memory` already has `retrieve_rate_limits`; extend the idea to the others or move it to the gateway with a per-user key.
- **Speak tokens are reusable within 10 minutes.** Each use is cheap and bounded (the structural slot check, capped at 16 slots, worst case about 1.2 ms), and a repeat after the brief is saved returns `unchanged`. Still, make the token single-use, or tie it to the brief id, and add a per-user limit on `close-session`.
- **A client can make TTS say a sequence of its own entity names.** Bounded by the slot check; decide whether to tighten it.
- **Speak names read is capped** (5,000 rows in one version, 1,000 rows per notebook in the final one). A name beyond the cap is refused and the brief is saved as text without audio. Make sure this stays safe and that the user sees a consistent fallback (see LM-77).
- **`retrieve-memory` validates a `limit` input it never uses.** Use it or remove it.
- **The brief RPC returns 22023 before `notFound` for non-owners with bad input.** No leak, but make the order consistent.

**Done when**
- A single user cannot exceed a stated rate on any model-backed route, speak tokens cannot be reused, and tests cover the limits.

**Source:** ledger Task 46 concerns and minors (throttles account-wide; `limit` unused; brief RPC order); R8; Task 56 minors and remaining concerns (speak token reuse, no per-user rate limit on close-session, client TTS sequence, row caps).

### LM-76: Data-model edges
**Area:** Supabase · **Size:** M · **Priority:** Before GA

Several edge cases in the stored data are known and unaddressed.

**Scope**
- **Entity metadata growth vs the 256 KiB commit cap.** Entity metadata merges by union with no per-key cap. A long-lived entity could grow past the cap, and then its turns are rejected (`invalidChange`) and dropped. Add a per-key and per-entity cap, or prune on merge, and test a long-lived entity.
- **`transcript_forgotten_at` is permanent.** New turns in a notebook whose transcript was auto-forgotten never refresh its card or brief (the safe direction, but a product trade-off), and owners can clear the marker themselves through the table UPDATE grant. Decide whether to reset it on new turns, and revoke the direct UPDATE.
- **Brief audio is not swept** by the auto-forget job (the brief stays after its transcript goes). Decide whether it should be.
- **An expired notebook shows an empty transcript with no message.** Show an explanation (UX in LM-77), and note that reopening such a notebook plays a fresh opening because there are no entries or turns.
- **Web `src/lib/supabase/types.ts` is not regenerated** (LM-51), and is now missing `kind`, `match_inside` and `name_words`. Regenerate it, and decide how to deal with the lint errors it causes (see LM-83).
- **`p_batch > 0` is not checked** in the auto-forget job.
- **`save_session_brief` replaces the brief whenever the source notebook differs,** so a late retry of an older notebook's brief overwrites a newer one. By design per the migration comment; only a Lambda-level race. Decide whether to guard it.
- **`authenticated` holds table-level TRUNCATE and DELETE grants** on several tables (Supabase defaults). Not exercised; review and revoke what the app does not need, with RLS in mind.
- **Session-deletion path has no catalog-driven guard test,** and `delete_notebook_test` does not assert the owner's own `maya` row is gone. Add both.
- **Extra profile round trip** in the retention flow (minor).

**Done when**
- Each item is fixed with a test, or recorded as accepted. The long-lived entity test shows commits keep working past the old cap.

**Source:** ledger Task 46 (minor, flag final review), Task 48 minors, Task 51 minors, Task 50; `task-integration-report.md` concern 8; recall report observations; ledger Phase 1 deferred list.

### LM-77: UX: failure and fallback states
**Area:** Flutter · **Size:** S · **Priority:** Before GA

Some failures and fallbacks are safe but silent, so the user cannot tell what happened.

**Scope**
- **The dock shows idle in the error state.** After the mic fix, a failed session is safe (the mic and the socket are closed) but looks like idle: no sign that the session failed. Show an error state and a way to retry.
- **The opening falls back when a brief has no audio.** When a name in the opening line is not in the graph (a learned name, or a user spelling that is not an alias), the brief is saved without audio, and the app plays the standard clip instead. Some briefs will therefore open generically. Decide what the user should see, and reduce the cases.
- **An expired notebook shows an empty transcript with no message** (LM-76).
- **A killed off-the-record session leaves an empty "Untitled" notebook** with no cleanup at next launch. Add a sweep.
- **Generic error copy in export** for all failures; add specific messages.
- **The dashboard lock IconButton adds a layout row** (LM-51); revisit the settings entry point.
- **Apple sign-in button is tappable while busy.**
- **A first-time user can reach a live session ungated** by opening an existing notebook with no conversation: the "Who hears you" gate runs only on new notebooks and mic taps. The Final fix wave's M1 passes the gate into `enterNotebook`; confirm on a device that no path skips it (LM-65).

**Done when**
- Each state has a visible message or a defined fallback and a widget test.

**Source:** ledger "Mic fix" minors; Task 56 remaining concerns (no-audio briefs); Task 51, 50, 52, 58 minors; `task-integration-report.md` concern 2.

### LM-78: Phase 2 residual minors
**Area:** Flutter · **Size:** S · **Priority:** Before GA

The last review of Phase 2 (787a44f) found it mergeable, with these minors left for follow-up tickets.

**Scope**
- **Stale-success re-trust race:** a stale successful forget check can re-trust a held brief after a newer check has started. Add a generation counter to `ForgetSync` so only the latest check can set trust.
- **Paging assumes `max_rows >= 1000`.** `accountEntityIds` pages the whole account's entities in pages of 1,000, and would silently drop entities if the server setting is lower. Read the page size from the response or fail closed.
- **`markLaunched` swallows errors,** so a failure causes a keychain wipe on every launch (R31). Surface the error and keep a retry counter.
- **The checklist should list all upgrade resets** (the one-time loss of the app-lock setting for builds before R31, and any other first-launch wipe).
- **A hard-coded key string** (reported without a location; find it).
- **`ForgetRedactor._load` vs an early `add()`** is a latent race. Order them.
- **Follow-up `null`** becomes `""` in the redacted request.
- **A stale pending "all" wipe** in the shared log could clear a new account's log (delete-only, privacy-safe); a **non-UTF-8 file** blocks recording until the next sweep.
- **Renamed ids reappear on the device only at the next snapshot.**

**Done when**
- Each minor is fixed with a test.

**Source:** ledger "Minor (→ follow-up tickets)" after the Phase 2 residual re-review; Task 63 minors; Task 57 minors; Task 63 concern 4.

### LM-79: Sign-in and passkey follow-ups
**Area:** Flutter + Supabase · **Size:** S · **Priority:** Later (passkey work depends on decision 4)

Small gaps in LM-58 that are not blockers.

**Scope**
- **Apple first-auth name can overwrite an existing account's `full_name`** on auto-link. Only write it if the account has none.
- **The full user agent is returned** by `list_my_sessions`, and the device label is coarse ("Lumen app" or "Web browser"). Return a trimmed label and have the app send a useful device name.
- **Anon tests do not prove the grant** for the device RPCs; add a test that `anon` cannot execute them.
- **Linking Apple re-authenticates on the phone only,** with no server-side recent sign-in. Either accept (and say so in the release notes) or add a server step.
- **No "sign out all other devices" button and no unlink for Apple.** Decide whether they are wanted.
- **File-level ignore comment placement** for the experimental passkey API.
- **Passkeys:** if the decision is yes, do the console setup (relying-party domain, AASA file, Associated Domains entitlement, Supabase Passkeys settings), test on a device, and flip the build define.

**Done when**
- Each item is fixed or accepted, and passkeys are either enabled with a device test or left off.

**Source:** Task 58 and its review minors; launch-checklist section 9.

### LM-80: App lock and file protection hardening
**Area:** Flutter + iOS · **Size:** S · **Priority:** Later

Minors from LM-47 and LM-52 that are small but touch the lock.

**Scope**
- **Quiet-mode setting** loads asynchronously and fails open until resolved.
- **Grace timing** uses the wall clock, and the grace restarts if the app is backgrounded during the Face ID sheet. Use a monotonic clock.
- **Stale `releasePending`** from an earlier resume, and a **hold timer** that survives the app resigning active.
- **`makeOpaque` hard-codes the paper colour.** Use the theme.
- **Journal files use `CompleteUnlessOpen`,** not `Complete` (the ticket said `Complete`). Keep and document, or move to `Complete` with a lock-aware write path.
- **`remove_entity` ("Remove") has no re-auth.** The brief named only forget and delete; decide whether to add it.
- **Export zip lingers in temp up to an hour,** or until the next launch or export. Delete it sooner if the share sheet allows.

**Done when**
- Each item is fixed or documented, and the lock gate tests cover the timing cases. Device checks are in LM-65.

**Source:** ledger Tasks 47 and 52 minors; `task-integration-report.md` concern 5; Task 47 concerns.

### LM-81: Alerts, secret migration and security-page links
**Area:** CDK + process · **Size:** S · **Priority:** Before GA

Gaps in what LM-45 and LM-54 could do from the repo.

**Scope**
- **The 4xx spike alarm** was built without denial logs, so it counts error responses only. Review what it can catch.
- **Bulk-read and Supabase admin-session alerts were not created;** `incident-response.md` records them as not alertable from this repo and plan-dependent (unverified). Re-check what the Supabase plan allows.
- **No alarms on the CloudTrail trail** (needs CloudWatch Logs, left out).
- **Move the edge functions to a custom-named `sb_secret_` key,** then disable the legacy keys (a code change; LM-45).
- **Link the vulnerability-disclosure page from `security.tsx`** (LM-54 follow-up), and add a short `SECURITY.md`.
- Confirm the host serves `/.well-known/security.txt` (dotfile path).

**Done when**
- Each alert either fires in a staging test or is recorded as not possible with the reason, the legacy keys are disabled, and the security page links to the disclosure process.

**Source:** ledger Task 45 follow-up; Task 54 report and review; Task 53 user actions; launch-checklist sections 5 and 8.

### LM-82: Privacy copy review
**Area:** Flutter + web · **Size:** S · **Priority:** Before GA

The Phase 1 and 2 copy was reviewed many times, but some minor wording points from the LM-53 review were deferred. Copy must say only what is true today.

**Scope**
- `security.tsx` "keeps each account's rows from other accounts" is ambiguous.
- "Nothing technically stops us yet" hints at a promise.
- "each turn's text" is true only for the user's turns.
- "for 7 days" was changed to "for about a week" (DynamoDB TTL lag); confirm every place uses the same wording, in the app and `security.tsx`.
- Make every claim traceable to a shipped ticket, and re-read all lines once the decisions (FINDING-6, Vertex, passkeys) and LM-73, LM-74 are settled.
- Keep `paidTierVerified` and `deviceList` out until their checks pass (LM-66, LM-68). Do not say "keeps nothing" or "we can't read it".

**Done when**
- Each sentence is traced to a shipped control, and `test/privacy_copy_test.dart` keeps the app and web copy in sync.

**Source:** ledger Task 53 minors; R6, R13; `docs/privacy-security-tickets.md` rules.

### LM-83: Test and CI hygiene
**Area:** Tests + CI · **Size:** M · **Priority:** Later

Reliability and maintenance issues in the tests and CI that were reported but not fixed.

**Scope**
- **A flaky test:** one full `flutter test` run failed once (`+959 -1`) in an existing test, and two reruns passed; the failing name was not captured. The recall report saw the same thing ("1 failure I did not identify"). Run the suite many times with the reporter set to capture names.
- **Timing assertions:** `infra/test/pseudonymized-requests.test.mjs` asserts the speak-check takes under 250 ms (loosened from 50 ms for CI), and others use similar bounds. Replace wall-clock bounds with work counters, or generous ones. Also, the new tests added about 80 s to the Flutter suite.
- **Source-grep tests:** some tests assert on source text (a test that `journal_provider.dart` no longer passes a live set, the shared-log instance test, and copy-sync checks against `security.tsx`). Replace them with behaviour tests where possible.
- **Web lint:** `eslint .` fails on the whole repo (935 errors on main; 748 after the format-only commit on Phase 1 server files). Most are in `src/lib/supabase/types.ts`. Regenerate `types.ts` (LM-76) and fix or scope the rest. Do not add blanket ignores.
- **The first CI run:** `.github/workflows/privacy-tests.yml` has never run on GitHub (LM-44 and Task 44). Check the first run, and make the Deno tests part of CI (`testing.md`'s default Deno command runs only `retrieve-memory`).
- **Small items from LM-44:** `safe-log.mjs` header names a test file that does not exist; `_shared/safe-log.ts` allowlists the key `error` (drop it); `retrieve-memory/eval.ts` still uses `console.log` (a dev script outside the scan); the measure script has a hard-coded `.env` path; cosmetic comment wrapping in `infra-stack.ts` and a migration header.
- **Commit `0df0e29` fails its web slug test** until `68b5653` (history fix; squash if you want each commit green).
- **Fixtures and stubs:** the export fixture is hand-written; Lambda stubs skip the SQL tokenizer (LM-72).
- **Repo hygiene:** `pubspec.lock` and `ios/Podfile.lock` are stale against `pubspec.yaml` by rule. Someone must commit the lock files deliberately when the dependency set is final. `docs/assets` regeneration and lock drift are environmental.

**Done when**
- The Flutter suite passes 20 times in a row, CI runs on GitHub with the Deno tests, and each small item is fixed or closed.

**Source:** `memory-recall-report.md` (first-run failure); Task 56 report (timing flake, timing assertions); ledger Tasks 44, 48, 52, 57 minors and Phase 2 residual items; `task-integration-report.md` concerns 1, 6 and 8; `phase2-integration-report.md`.

---

## Already ticketed or fixed (not repeated)

- **Phase 3** (LM-59 to LM-62) is already ticketed. It needs D1 and D2 first.
- **Fixed in the integration and fix waves:** the redaction of Removes and ordinary words (C1), forgotten names surviving in text (C2), off-the-record resumption (I1), the brief after forget (I2), forget for non-Latin names via the slug check (I3, residual R3), reappearing after relaunch (I4), retention confirmation (I5), U+0001 in a transcript (I7), names of four or more tokens (R2), reconnect token and stale handle (R5), card staleness after forget (R6), the mic running in the error state, the redacted transcript copy for BUG-2 (LM-63), BUG-3, BUG-4, BUG-5 and BUG-7, the Phase 2 final review's sign-out, cross-device forget, shared-log owner scope and checklist items, and R31.
- **Closed in the checklist:** the account-deletion and Apple-revocation blockers are listed in section 1 (the work is LM-64), and the legacy `extract-graph` deletion is section 2 step 2 (the work is LM-67).

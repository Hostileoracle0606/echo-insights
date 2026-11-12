# Phase 1 and 2 launch checklist (LM-43 to LM-58, LM-63)

Every open user action across Phases 1 and 2, in the order to do them. Built from the SDD ledger and the ticket docs. Nothing here has been done by an agent: no deploys, no console changes, no pushes. Mark **(unverified)** items before relying on them.

## 1. Before anything ships

- [ ] Read the first CI run of `.github/workflows/privacy-tests.yml` (LM-44: it has not run on GitHub yet).
- [ ] Merge one branch: `chore/phase2-integration`. It holds Phase 1 (twelve tickets and the reconciliation migration) and Phase 2 (LM-55, 56, 57, 58, 63 and the final fix wave), tested together. Do not merge the ticket branches one by one: `feat/lm-49-forget-person` on its own drops LM-46's RPC caps, and only this branch carries `…700`.
- [ ] Never commit `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.

**Launch blockers (App Store and privacy), not built yet. Do not submit without them:**
- [ ] **In-app account deletion** (App Store Review Guideline 5.1.1(v)): an app that lets people create an account must let them delete it inside the app. Lumen has "delete a session" and "forget a person" but no "delete my account".
- [ ] **Apple token revocation on account deletion**: with Sign in with Apple, deleting the account must also revoke the Apple token through Apple's REST API (`/auth/revoke`), which needs a Sign in with Apple key and a server-side call. Build both together with the item above.

## 2. Deploy order

**Phase 2 (integrated branch `chore/phase2-integration`), the whole order at a glance.** One branch carries Phase 1 plus LM-55, 56, 57, 58 and 63. Merge only that branch. The three steps below are in this order and none may be skipped or swapped: (A) all migrations, (B) edge functions and the runtime (`cdk deploy` / Lambdas), (C) the iOS app and the web app.

(A) Migrations (17), applied in file-name order (`supabase db push` does this; staging first):

| # | Migration | Ticket |
|---|-----------|--------|
| 1 | `20261104000000_rpc_input_caps.sql` | LM-46 |
| 2 | `20261104000100_complete_deletion.sql` | LM-48 |
| 3 | `20261104000200_forget_person.sql` | LM-49 |
| 4 | `20261104000300_forget_regeneration.sql` | LM-49 |
| 5 | `20261104000350_auto_forget.sql` | LM-51 |
| 6 | `20261104000360_auto_forget_followups.sql` | LM-51 |
| 7 | `20261104000400_export_my_data.sql` | LM-52 |
| 8 | `20261104000500_delete_empty_notebook.sql` | LM-50 |
| 9 | `20261104000600_privacy_screen_seen.sql` | LM-53 |
| 10 | `20261104000700_reconcile_rpc_caps.sql` | integration |
| 11 | `20261104000800_forget_scope.sql` | LM-49 review |
| 12 | `20261104000900_forget_residual.sql` | LM-49 re-review |
| 13 | `20261107000000_brief_without_audio.sql` | LM-56 |
| 14 | `20261112000000_device_sessions.sql` | LM-58 |
| 15 | `20261112100000_forget_everywhere.sql` | LM-63 |
| 16 | `20261112100100_context_text_backfill.sql` | LM-63 |
| 17 | `20261112200000_forgotten_marker.sql` | Phase 2 fix wave (a forget reaches other phones) |

LM-55 and LM-57 have no migration. Timestamps are unique and strictly increasing; `20261107…` (LM-56) and the `202611122…` and `20261112100…` files (LM-63 and the fix wave) build on `…700`'s function bodies and are applied after it, so the caps survive. **`…200000` must be live before the iOS build ships:** the app asks `forgotten_marker()` for a forget made on another phone, and while that call fails it does not play the held opening brief.

(B) Then the edge functions and runtime (section 2, steps 2 and 3 below). (C) Then the iOS build, and only after it is released, the web app (steps 6 and 7). `/security` describes iPhone-only controls, so it must not go live before the build that has them.

Detail for each step follows.

Staging first, then production. Do not use production for testing.

1. **Database migrations, all of them, before the `close-session` Lambda.** In order: `20261104000000_rpc_input_caps.sql` (LM-46), `20261104000100_complete_deletion.sql` (LM-48), `20261104000200_forget_person.sql` and `20261104000300_forget_regeneration.sql` (LM-49), `20261104000350_auto_forget.sql` and `20261104000360_auto_forget_followups.sql` (LM-51), `20261104000400_export_my_data.sql` (LM-52), `20261104000500_delete_empty_notebook.sql` (LM-50), `20261104000600_privacy_screen_seen.sql` (LM-53), `20261104000700_reconcile_rpc_caps.sql` (integration), `20261104000800_forget_scope.sql` (final review), `20261104000900_forget_residual.sql` (re-review), then `20261107000000_brief_without_audio.sql` (LM-56, #13) and `20261112000000_device_sessions.sql` (LM-58, #14; section 9 has its own post-migration check).
   Then, for LM-63, `20261112100000_forget_everywhere.sql` (#15) and after it `20261112100100_context_text_backfill.sql` (#16; fills what Lumen reads for users who already forgot someone; row locks only, safe to re-run), and last `20261112200000_forgotten_marker.sql` (#17, the fix wave). **The iOS app ships after these:** it reads `context_text`, and against a database without the column it loses saved history and can't write a card or brief. The `extract-graph` Lambda (step 3) calls `redact_forgotten_text`, which exists since `…300`.
   **Take a backup first.** `…200` rehashes `entity_suppressions` one way: the readable slugs are gone afterwards and nothing can turn the hashes back. After `…800`, every existing row counts as `removed`.
   Why `…700` follows them: LM-49's `…300` redefines `save_session_card` and `save_session_brief` without LM-46's caps, so applying them in order silently drops the caps until `…700` restores them. `…700` also makes `delete_empty_notebook` keep a notebook auto-forget emptied.
   **Post-migration check (staging, then production):** an oversized card call to `save_session_card` must be refused, a card naming a forgotten person must be stored redacted, and a card mentioning a merely removed word must be stored unchanged. Do not proceed to the Lambda deploy if either fails.
   Why the migrations come first: the new `close-session` code calls an RPC from `…300`. If the Lambda ships first, every session close returns 503 (it fails closed). The LM-51 migrations `…350` and `…360` ship together with the Lambda.
2. **Edge functions** (LM-44 and LM-46 changed them), after the migrations: `supabase functions deploy embed-entities`, `retrieve-memory` and `speak-agent`, each with `--project-ref bjoevzvsdlhlcjywpyfx` (use the staging ref first when testing). **Delete the legacy `extract-graph` edge function, do not redeploy it:** nothing calls it (the app uses the runtime's extraction route) and it has no forget redaction, so leaving it live is a way around LM-63: `supabase functions delete extract-graph --project-ref ...`. Delete `speak-agent` too if you retire it (section 4).
3. **`cdk deploy`** (your own deploy, with the Supabase parameters). Add `-c alertEmail=<your address>` so alerts reach you. This creates the log groups (LM-44), the per-route throttles (LM-46), the alerts topic and alarms, and the CloudTrail trail and its bucket (LM-54).
4. **Confirm the alert email subscription** (click the link AWS sends). Unconfirmed means no alerts.
5. **Delete the old auto-created `/aws/lambda/*` log groups** for the functions (LM-44), only after the `cdk deploy` step. They never expire and may hold old content.
6. **Ship the iOS build** only after steps 1 to 3 are live and the blockers in section 1 are done.
7. **Deploy the web app after the iOS build is released**, not before: `/security` lists iPhone-only controls (the shared log, forget a person, off the record, auto-forget) that are only true once the build is out. Confirm the host serves `/.well-known/security.txt` (dotfile path). `src/lib/journal-store.ts` also has the new slug rule.

## 3. Accounts and access (LM-45), do first, any time

- [ ] Supabase: MFA on your account; enforce for the org if the plan allows (unverified); confirm you are the only member.
- [ ] AWS root: MFA (hardware key or passkey), no root access keys. IAM users: MFA, remove unused users and keys.
- [ ] GitHub: 2FA; review collaborators and Actions secrets.
- [ ] CI target: confirm `vars.SUPABASE_PROJECT_REF` in the `staging` environment is a **staging** project, and `SUPABASE_ACCESS_TOKEN` is not from an account that can reach production.
- [ ] Rotate keys in the order in `admin-access.md` section B: Gemini key first, then Supabase credentials (rotating the legacy key is an outage: read that section first). Also the production DB password and personal access token listed there.
- [ ] Name a legal / privacy adviser for incidents (`incident-response.md`).

## 4. AI provider and billing (LM-43)

- [ ] Enable billing on the Google Cloud project that owns the key in secret `echo-insights/gemini-api-key`, and on the one behind `VITE_GEMINI_API_KEY` (web), or retire that path.
- [ ] AI Studio, Logs and Datasets: turn project logging off unless you want retention; create no datasets.
- [ ] Run a 10-call burst against the billed key and confirm no 429s (no key on the command line).
- [ ] Check and remove the Groq (`extract-graph`) and ElevenLabs (`speak-agent`) edge functions and secrets if unused.
- [ ] Ask Google Cloud support in writing the four questions in `ai-processing.md` section 4.
- [ ] Then flip `paidTierVerified` to `true` in `lib/privacy/privacy_claims.dart`. Do not claim "keeps nothing": the paid Gemini API has no documented zero-retention mode.

## 5. Alerts and security readiness (LM-54)

- [ ] Fire each alarm once on purpose in staging (make a function throw, or lower a threshold) and confirm the email arrives. The ticket's "alerts fire in a test" is not done until you do.
- [ ] Set a budget/usage alert on the Gemini key in the Google console (unverified in the UI).
- [ ] Check whether the Supabase plan offers audit logs, statement logging or log drains (unverified); record the answer in `incident-response.md`.
- [ ] If the AWS account already has a CloudTrail trail, remove one before deploying (a second copy of management events is charged).
- [ ] Enable GitHub private vulnerability reporting (repository Settings, Code security) so `vulnerability-disclosure.md` works; consider a short `SECURITY.md` pointing to it.
- [ ] **Penetration test:** book a firm, give them `pentest-scope.md`, a staging project and synthetic accounts. Fix or accept each finding in its table. Done only with no open Critical or High.

## 6. On a real device (LM-47, LM-52, LM-50)

- [ ] **Face ID test:** lock on resume with no flash of content, grace period, turning the lock off asks for re-auth, re-auth before export, "Delete this session" and forget a person, local file protection. The simulator cannot prove these.
- [ ] **On the simulator or a device, signed in:** delete a session (confirm, Face ID, it's gone from the dashboard, a failed Face ID keeps it). Forget a person (preview counts match, Face ID, name gone from cards and from other people's notes, mentioning the same name later doesn't bring them back, and that holds after a relaunch). Also a name with no Latin letters. Shorten retention (confirm, then Face ID).
- [ ] Export: the real share sheet and AirDrop. The zip may linger in temp up to an hour, so copy must not say "deleted immediately".
- [ ] Off the record: start and leave a session, check no notebook remains. Go on, say something, come back on, and check Lumen doesn't refer to it; expect a short reconnect. Killing the app mid-session may leave an empty "Untitled" notebook (known).

## 7. Flags and copy (LM-53)

- [ ] `shipped` in `lib/privacy/privacy_claims.dart` already lists forget a person, off the record and auto-forget, so those lines appear in the first build from this branch. Ship that build only after sections 2 and 6, or take a control out of the set first.
- [ ] Flip `paidTierVerified` only after section 4.
- [ ] `PrivacyFeature.deviceList` is **not** in `shipped` (ruling R30): its line is off the Privacy screen and `/security`. Put it in `shipped`, and put its line back in `IPHONE_CONTROLS` in `src/routes/security.tsx` (the text is `gatedClaims[PrivacyFeature.deviceList]`), only after the staging check in section 9 passes. `test/privacy_copy_test.dart` fails if the two drift. Ship the iOS build first, then the web page.
- [ ] Do not claim "we can't read it" (Phase 3) or "keeps nothing".

## 8. Known follow-ups, not blocking Phase 1 or 2

- Move the edge functions to a custom-named `sb_secret_` key, then disable the legacy keys (LM-45).
- Retire or document Groq, ElevenLabs, the web `VITE_GEMINI_API_KEY`, and Live session resumption (LM-43).
- Web `types.ts` not regenerated (LM-51).

## 9. Sign in with Apple, passkeys, device list (LM-58)

Console work only you can do. The repo side does not touch Apple or the Supabase project. Facts checked 2026-11-12 against Supabase's docs (links in `.superpowers/sdd/privacy-security-tickets/task-58-report.md`); mark anything that differs on your screen as **(unverified)**.

**Order:** migration `20261112000000_device_sessions.sql` is no. 14 of the full list in section 2 (staging, then production; apply the whole list, not this one alone), then the Supabase and Apple settings below, then the iOS build. The device-list line on the Privacy screen and `/security` is only true once that migration is live.

**Sign in with Apple (native iOS flow)**
- [ ] Apple Developer, Identifiers, App ID `com.echoinsights.lumen`: turn on the **Sign in with Apple** capability (Enable as a primary App ID).
- [ ] Regenerate the provisioning profile for that App ID and let Xcode pick it up. `ios/Runner/Runner.entitlements` already has `com.apple.developer.applesignin`. The simulator builds without this; a device build will not sign until the profile has the capability.
- [ ] Supabase dashboard, Authentication, Sign In / Providers, **Apple**: enable it and put **`com.echoinsights.lumen`** in *Client IDs* (the native flow needs only the bundle ID). If you later add a web "Sign in with Apple", create a Services ID, a key and a client secret, and put the Services ID **first** in that field. Do not paste the key anywhere but the dashboard. Apple client secrets expire (6 months) **(unverified for this setup)**: calendar a rotation if you add the web flow.
- [ ] Supabase dashboard, Authentication, Sign In / Providers, **Allow manual linking**: turn on. Without it "Link" in Privacy fails.
- [ ] Hidden email: if you ever send mail to Apple relay addresses, register your sending domain under Sign in with Apple for Email Communication. The app itself sends nothing to them; Supabase's confirmation emails to a relay address need this **(unverified)**.
- [ ] Test on a real device (the simulator has no Apple ID for this): new Apple account (the intro plays), existing email account (same email: Supabase links it automatically; a hidden email is a different address, so it creates a **separate** account, and you link it from Privacy, Sign-in and devices), cancel the sheet, revoke the app in iOS Settings and sign in again (the name arrives once only).

**Passkeys (Supabase beta, experimental in `supabase_flutter`)**
Off in the app until you do all of this and build with `--dart-define=PASSKEYS_ENABLED=true`.
- [ ] Pick the relying party domain you control (a bare domain, e.g. the web app's). Changing it later breaks every enrolled passkey.
- [ ] Host `https://<domain>/.well-known/apple-app-site-association` (JSON, no redirect) with a `webcredentials` entry listing `<TeamID>.com.echoinsights.lumen`. Confirm the host serves that path **(unverified: the web host may need a rule)**.
- [ ] Xcode: add the **Associated Domains** capability with `webcredentials:<domain>` to the App ID, the profile and `Runner.entitlements`. Not added in the repo, because the domain is yours to choose.
- [ ] Supabase dashboard, Authentication, **Passkeys**: enable; set the Relying Party Display Name (Lumen), Relying Party ID (the bare domain) and up to 5 origins (HTTPS, each matching or under the ID).
- [ ] Beta caveat: Supabase may change the API without notice, and the community reports registration errors. Decide whether a beta is acceptable for production before flipping the define.
- [ ] Test on a device: add a passkey in Privacy, sign out, sign in with it; cancel the prompt; an account with an email and a passkey is still one account.

**Device list**
- [ ] Confirm the project's JWT expiry is 3600 seconds or less (Authentication, Sessions / JWT settings). The Privacy line says a signed-out device may keep working "for up to an hour"; that is the access token's life, which a revoke cannot shorten.
- [ ] Confirm no Supabase setting (time-box, inactivity timeout, single session per user) conflicts with what you want the list to show.
- [ ] Post-migration check (staging): sign in on two simulators, sign one out from the other, then confirm the first fails to refresh. Then confirm `select * from auth.sessions` is still unreadable to the `authenticated` role.
- [ ] **Flag check, hosted facts (R30), required before `deviceList` ships:** on staging, run `select has_table_privilege('postgres', 'auth.sessions', 'DELETE')` and, as the `authenticated` role, call `revoke_my_session` on a second session (it must return true and the row must be gone); confirm the JWT expiry setting is 3600 seconds or less. Both must hold; if either fails, leave the flag off and change the copy. Then do the flip in section 7.
- [ ] **Linking Apple re-authenticates on the phone only:** Face ID or the passcode (local re-auth) before "Link", and nothing server-side: Supabase does not ask for a recent sign-in to link an identity. Anyone with the unlocked phone and its passcode can link their own Apple ID. State this in the release notes or accept it.
- [ ] **Sign out of this phone** (Privacy, Sign-in and devices): signs this phone out only (scope local), erases the name map, the forgotten-name hashes, What Lumen shared and the held brief, and shows login. Test on a device: a hidden-email Apple account can sign out and back in with the real account; "this device" in the list is not offered a remote sign-out, this button is its action.
- [ ] **A forget on one phone reaches the other (I2):** forget a person on phone A; open phone B (or bring it to the foreground). Its What Lumen shared is empty, the next opening does not use the held brief, and the Keychain name map no longer has that person. With phone B offline at that moment, its held brief must not play until it is online again.
- [ ] **Reinstall wipes the Keychain (R31):** on the first launch after an install, the app deletes `privacy.pseudonym_map`, `privacy.forgotten_names`, `privacy.forget_marker`, the app-lock switch and the quiet-mode switch (a UserDefaults flag, which iOS deletes with the app, tells a fresh install from a relaunch). Test on a device: sign in, forget a person, delete the app, reinstall; the name map and forgotten hashes are gone, app lock is off, and the first launch after that wipes nothing. Anyone who already has a build from before this change loses their app-lock setting once, on the first launch of this version.

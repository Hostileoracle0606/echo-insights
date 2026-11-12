# Phase 1 launch checklist (LM-43 to LM-54)

Every open user action across Phase 1, in the order to do them. Built from the SDD ledger and the ticket docs. Nothing here has been done by an agent: no deploys, no console changes, no pushes. Mark **(unverified)** items before relying on them.

## 1. Before anything ships

- [ ] Read the first CI run of `.github/workflows/privacy-tests.yml` (LM-44: it has not run on GitHub yet).
- [ ] Merge one branch: `chore/phase1-integration`. It holds all twelve tickets, the reconciliation migration and the cross-ticket wiring, tested together. Do not merge the ticket branches one by one: `feat/lm-49-forget-person` on its own drops LM-46's RPC caps, and only this branch carries `…700`.
- [ ] Never commit `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.

## 2. Deploy order

Staging first, then production. Do not use production for testing.

1. **Database migrations, all of them, before the `close-session` Lambda.** In order: `20261104000000_rpc_input_caps.sql` (LM-46), `20261104000100_complete_deletion.sql` (LM-48), `20261104000200_forget_person.sql` and `20261104000300_forget_regeneration.sql` (LM-49), `20261104000350_auto_forget.sql` and `20261104000360_auto_forget_followups.sql` (LM-51), `20261104000400_export_my_data.sql` (LM-52), `20261104000500_delete_empty_notebook.sql` (LM-50), `20261104000600_privacy_screen_seen.sql` (LM-53), `20261104000700_reconcile_rpc_caps.sql` (integration), `20261104000800_forget_scope.sql` (final review), and last `20261104000900_forget_residual.sql` (re-review).
   Then, for LM-63, `20261112100000_forget_everywhere.sql` and after it `20261112100100_context_text_backfill.sql` (fills what Lumen reads for users who already forgot someone; row locks only, safe to re-run). **The iOS app ships after these:** it reads `context_text`, and against a database without the column it loses saved history and can't write a card or brief. The `extract-graph` Lambda (step 3) calls `redact_forgotten_text`, which exists since `…300`.
   **Take a backup first.** `…200` rehashes `entity_suppressions` one way: the readable slugs are gone afterwards and nothing can turn the hashes back. After `…800`, every existing row counts as `removed`.
   Why `…700` follows them: LM-49's `…300` redefines `save_session_card` and `save_session_brief` without LM-46's caps, so applying them in order silently drops the caps until `…700` restores them. `…700` also makes `delete_empty_notebook` keep a notebook auto-forget emptied.
   **Post-migration check (staging, then production):** an oversized card call to `save_session_card` must be refused, a card naming a forgotten person must be stored redacted, and a card mentioning a merely removed word must be stored unchanged. Do not proceed to the Lambda deploy if either fails.
   Why the migrations come first: the new `close-session` code calls an RPC from `…300`. If the Lambda ships first, every session close returns 503 (it fails closed). The LM-51 migrations `…350` and `…360` ship together with the Lambda.
2. **Edge functions** (LM-44 and LM-46 changed them), after the migrations: `supabase functions deploy embed-entities`, `retrieve-memory`, `extract-graph` and `speak-agent`, each with `--project-ref bjoevzvsdlhlcjywpyfx` (use the staging ref first when testing). Delete `extract-graph` and `speak-agent` instead if you retire them (section 4).
3. **`cdk deploy`** (your own deploy, with the Supabase parameters). Add `-c alertEmail=<your address>` so alerts reach you. This creates the log groups (LM-44), the per-route throttles (LM-46), the alerts topic and alarms, and the CloudTrail trail and its bucket (LM-54).
4. **Deploy the web app**, so `/security` and `/.well-known/security.txt` are live with the same claims as the iOS build. Confirm the host serves the dotfile path. `src/lib/journal-store.ts` also has the new slug rule.
5. **Confirm the alert email subscription** (click the link AWS sends). Unconfirmed means no alerts.
6. **Delete the old auto-created `/aws/lambda/*` log groups** for the functions (LM-44), only after the `cdk deploy` step. They never expire and may hold old content.
7. Ship the iOS build only after steps 1 to 4 are live.

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
- [ ] Do not claim "we can't read it" (Phase 3) or "keeps nothing".

## 8. Known follow-ups, not blocking Phase 1

- Move the edge functions to a custom-named `sb_secret_` key, then disable the legacy keys (LM-45).
- Retire or document Groq, ElevenLabs, the web `VITE_GEMINI_API_KEY`, and Live session resumption (LM-43).
- Web `types.ts` not regenerated (LM-51).

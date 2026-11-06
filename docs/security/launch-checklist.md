# Phase 1 launch checklist (LM-43 to LM-54)

Every open user action across Phase 1, in the order to do them. Built from the SDD ledger and the ticket docs. Nothing here has been done by an agent: no deploys, no console changes, no pushes. Mark **(unverified)** items before relying on them.

## 1. Before anything ships

- [ ] Read the first CI run of `.github/workflows/privacy-tests.yml` (LM-44: it has not run on GitHub yet).
- [ ] Merge in stack order (branches sit on each other, so PRs show the lower commits until they merge): 44, 46, 48, then 49 and 51 (both on 48), 47, then 52 (on 47), then 53 (on 52), 50, 43, 45, 54 (on 44).
- [ ] Never commit `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.
- [ ] LM-48 follow-up: the delete-session path should call the re-auth helper (LM-47) once both are merged.

## 2. Deploy order

Staging first, then production. Do not use production for testing.

1. **Database migrations, all of them, before the `close-session` Lambda.** In order: `20261104000000` (LM-46 RPC caps), `20261104000100` (LM-48), `20261104000200` (LM-49), `20261104000300` (LM-49 forget_regeneration), `20261104000350` and its companion `20261104000360` (LM-51 auto-forget), `20261104000400` (LM-52 export), `20261104000500` (LM-50 `delete_empty_notebook`).
   Why: the new `close-session` code calls an RPC from `…300`. If the Lambda ships first, every session close returns 503 (it fails closed). The LM-51 migrations `…350` and `…360` ship together with the Lambda.
2. **`cdk deploy`** (your own deploy, with the Supabase parameters). Add `-c alertEmail=<your address>` so alerts reach you. This creates the log groups (LM-44), the per-route throttles (LM-46), the alerts topic and alarms, and the CloudTrail trail and its bucket (LM-54).
3. **Confirm the alert email subscription** (click the link AWS sends). Unconfirmed means no alerts.
4. **Delete the old auto-created `/aws/lambda/*` log groups** for the functions (LM-44), only after step 2. They never expire and may hold old content.
5. Ship the iOS build only after steps 1 and 2 are live.

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
- [ ] Then flip `paidTierVerified` to `true` in `lib/privacy/privacy_claims.dart` (on the LM-53 branch). Do not claim "keeps nothing": the paid Gemini API has no documented zero-retention mode.

## 5. Alerts and security readiness (LM-54)

- [ ] Fire each alarm once on purpose in staging (make a function throw, or lower a threshold) and confirm the email arrives. The ticket's "alerts fire in a test" is not done until you do.
- [ ] Set a budget/usage alert on the Gemini key in the Google console (unverified in the UI).
- [ ] Check whether the Supabase plan offers audit logs, statement logging or log drains (unverified); record the answer in `incident-response.md`.
- [ ] If the AWS account already has a CloudTrail trail, remove one before deploying (a second copy of management events is charged).
- [ ] Enable GitHub private vulnerability reporting (repository Settings, Code security) so `vulnerability-disclosure.md` works; consider a short `SECURITY.md` pointing to it.
- [ ] After LM-53 merges, link the disclosure policy from `src/routes/security.tsx`.
- [ ] **Penetration test:** book a firm, give them `pentest-scope.md`, a staging project and synthetic accounts. Fix or accept each finding in its table. Done only with no open Critical or High.

## 6. On a real device (LM-47, LM-52, LM-50)

- [ ] **Face ID test:** lock on resume with no flash of content, grace period, turning the lock off asks for re-auth, re-auth before export and delete, local file protection. The simulator cannot prove these.
- [ ] Export: the real share sheet and AirDrop. The zip may linger in temp up to an hour, so copy must not say "deleted immediately".
- [ ] Off the record: start and leave a session, check no notebook remains. Killing the app mid-session may leave an empty "Untitled" notebook (known).

## 7. Flags and copy (LM-53)

- [ ] Set `shipped` (the set of privacy features that are live, in `lib/privacy/privacy_claims.dart`) to list each control that is actually live, after steps in sections 2 and 6.
- [ ] Flip `paidTierVerified` only after section 4.
- [ ] Do not claim "we can't read it" (Phase 3) or "keeps nothing".

## 8. Known follow-ups, not blocking Phase 1

- Move the edge functions to a custom-named `sb_secret_` key, then disable the legacy keys (LM-45).
- Retire or document Groq, ElevenLabs, the web `VITE_GEMINI_API_KEY`, and Live session resumption (LM-43).
- Web `types.ts` not regenerated (LM-51); web vitest not run (LM-53).

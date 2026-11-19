# Release 1 deploy runbook (LM-120 staging, LM-125 production)

One page, the same order twice. Run it on **staging** first (LM-120). Run it again on **production** (LM-125) only after LM-120 to LM-124 pass. It is built from `launch-checklist.md` section 2 plus the release 1 changes: the new `delete-account` function, the deleted `extract-graph` edge function, the LM-102/103 migration, and passkeys.

**Scope decision (2026-11-17):** only the iOS release matters for release 1. The web app is out of scope except two files that go out early, before iOS submission: `/privacy` (the App Store privacy policy URL) and `/.well-known/apple-app-site-association` (passkeys). `/security` and the rest of the web app are **not** deployed for release 1 (section 5). **No penetration test in release 1:** it is deferred to after release 1, not dropped (LM-68).

Nothing here has been run by an agent. Every command is yours to type. Items marked **(unverified)** are not established from this repo; check them before relying on them.

## 0. Before you type anything

1. Set the target once per terminal, then check it. Do not type a project ref from memory.

   ```bash
   export REF=<STAGING_REF>          # production: export REF=bjoevzvsdlhlcjywpyfx
   ```

2. The ref must be the one you mean. Production is `bjoevzvsdlhlcjywpyfx`. The project `giyjrvixpbfnourkpsen` is a decoy: never link it, never push to it, never put it in `REF`.

   ```bash
   supabase projects list            # your REF must appear; stop if it does not
   supabase link --project-ref "$REF"
   supabase migration list           # Local and Remote columns; read them before step 2
   ```

3. Work from the merged release branch (LM-128 done, LM-114 to LM-118 and LM-127 merged), clean checkout. `git status` must show nothing, and never commit `pubspec.lock`, `ios/Podfile.lock` or `docs/assets`.
4. Staging only: your AWS profile and Supabase login must be the staging ones. Production steps use the production ones. A staging run that touches production is the failure this page exists to prevent.

## 1. Backup first

`…200000_forgotten_marker.sql` rehashes `entity_suppressions` one way: the readable slugs are gone afterwards and nothing turns the hashes back. Take the backup before the first migration, on both projects.

```bash
supabase db dump --linked -f "backup-$REF-schema-$(date +%Y%m%d).sql"
supabase db dump --linked --data-only -f "backup-$REF-data-$(date +%Y%m%d).sql"
```

- `supabase db dump` runs `pg_dump` in a container, so Docker must be running **(unverified for your CLI version; `supabase db dump --help` says)**.
- The data file holds real journals. Keep it encrypted, off shared drives, and delete it once the rehearsal is signed off. On production keep it until you are sure.
- Also note the dashboard backup state for the project (Database, Backups) **(unverified: plan-dependent)**.
- Check the files are not empty (`ls -l backup-*`).

## 2. Migrations, in file-name order

`supabase db push` applies pending files in file-name order. Run it once and read the list it prints before you confirm.

```bash
supabase db push --linked --dry-run   # lists what it would apply; compare with the table
supabase db push --linked
```

If a file sorts before one already applied remotely, `db push` refuses; do not force it until you know why (`--include-all` exists, and applies out-of-order files).

| # | File | Ticket |
|---|------|--------|
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
| 17 | `20261112200000_forgotten_marker.sql` | Phase 2 fix wave |
| 18 | `20261112300000_forget_erase_transcripts.sql` | Forget: opt-in erase |
| 19 | `20261116000000_card_brief_idempotency.sql` | LM-102/103 |
| 20 | `20261116000050_card_draft_key.sql` | LM-102/103 |
| 21 | `20261116000060_brief_status_shape.sql` | LM-102/103 |
| 22 | `20261116000100_erase_batch_keys.sql` | LM-102/103 |
| 23 | `20261116000200_unfinished_work.sql` | LM-102/103 |
| 24 | `20261117000000_account_deletion_flow_state.sql` (purges `auth.flow_state` on account deletion; best-effort, a failed purge is only a Postgres warning) | LM-117 |
| 25 | **`<ADD NEW 20261118… FILES HERE, IN FILE-NAME ORDER>`** Two sessions are still adding migrations (timestamps `20261118000100` to `20261118000900`). Run `ls supabase/migrations` on the final release branch and copy every file that is newer than row 24 into this table before the rehearsal. | account deletion worker and others |

The list above is the whole set on `feat/release-beta-forget` as of 2026-11-18 plus the open row. The count in `launch-checklist.md` ("18") is out of date for release 1.

Why this order: `…300` drops LM-46's caps and `…700` restores them, so a partial run leaves the caps off. `…200000` must be live before the iOS build ships. The new `close-session` code calls an RPC from `…300` and selects `is_draft` (added by the LM-102 migrations), so the `close-session` Lambda deploys only after **all** migrations, including every `20261118…` file; otherwise every session close returns 503.

### Post-migration check (do not go on if either fails)

On the target project, as a test user (never a real one):

1. An oversized card call to `save_session_card` is **refused**.
2. A card naming a forgotten person is stored **redacted**.
3. A card mentioning a merely removed word is stored **unchanged**.
4. `supabase migration list` shows every file in the table as applied on the Remote side.

### Sign-in audit log (dashboard, staging first, then production)

Standard practice for this release: Supabase writes a sign-in audit log into the database by default, and those rows hold the user id and email. Turn it off:

1. Supabase dashboard, the target project, Authentication, Audit Logs: switch **"Write audit logs to the database" off**. Save.
2. Write the date down. **(unverified: the exact label and where the toggle lives may differ on your dashboard; if it is not there, record what you see and stop.)**
3. The account deletion worker (built by another session) purges a deleted user's `auth.audit_log_entries` and `auth.flow_state` rows. After a staging test deletion, check both tables for the deleted user's id and expect no rows. The only record kept is the user id and timestamps in `account_deletion_requests`. **<CONFIRM the table and the check query once the worker merges.>**
4. Sign-in records that remain in the provider's own logs are kept for a limited time set by the provider, then removed. That sentence is on `/privacy`; do not say more than that.

## 3. Edge functions

Deploy after the migrations. All with `--project-ref "$REF"`.

```bash
supabase functions deploy embed-entities  --project-ref "$REF"
supabase functions deploy retrieve-memory --project-ref "$REF"
supabase functions deploy speak-agent     --project-ref "$REF"
supabase functions deploy delete-account  --project-ref "$REF"
```

- `delete-account` is new in release 1 (LM-114). Deploy it **without** `--no-verify-jwt`, so the platform also checks the JWT. Before the first test deletion, set its Sign in with Apple secrets from an **untracked** env file (never commit it, never pass values inline; delete the file afterwards):

  ```bash
  # apple.env (untracked, in a folder outside the repo)
  #   APPLE_TEAM_ID=...      Apple Developer, Membership details
  #   APPLE_KEY_ID=...       Keys, a key with Sign in with Apple enabled
  #   APPLE_PRIVATE_KEY=...  the .p8 PEM, downloaded once
  #   APPLE_CLIENT_ID=com.echoinsights.lumen
  supabase secrets set --env-file /path/outside/repo/apple.env --project-ref "$REF"
  ```

  Without these the function still deletes the account and answers `apple_revoked:false`.
- If you retire `speak-agent` (checklist section 4), leave its line out and run `supabase functions delete speak-agent --project-ref "$REF"`.

Delete the legacy Groq function. Its source is gone from the repo (LM-118), so nothing redeploys it, but a copy deployed earlier keeps running with no forget redaction.

```bash
supabase functions list --project-ref "$REF"                  # is extract-graph there?
# Dashboard, Edge Functions, extract-graph, Invocations: look at recent calls first.
supabase functions delete extract-graph --project-ref "$REF"
supabase secrets unset GROQ_API_KEY --project-ref "$REF"
supabase functions list --project-ref "$REF"                  # extract-graph is gone
```

The AWS Lambda also called `extract-graph` is the live Gemini route. It is not touched by this step.

## 4. AWS: `cdk deploy`

Your own deploy, with the Supabase parameters you normally pass. The alert address is required so alerts reach you.

```bash
cd infra
npx cdk deploy -c alertEmail=<your address> <your usual Supabase context flags>
```

Then:
1. Click the confirmation link in the email AWS sends. Unconfirmed means no alerts.
2. Only after the deploy, delete the old auto-created `/aws/lambda/*` log groups for the functions (they never expire).

## 5. Passkeys console steps and the early web files (LM-127, LM-119)

The relying-party domain is `lumen.trigo.workers.dev` (already in `ios/Runner/Runner.entitlements`). It cannot change after people enroll passkeys.

1. **Apple Team ID:** put your 10-character Team ID in `public/.well-known/apple-app-site-association` in place of `REPLACE_WITH_APPLE_TEAM_ID` (Apple Developer, Membership details). It is still a placeholder. Commit that change.
2. **Apple Developer, Identifiers, `com.echoinsights.lumen`:** turn on Associated Domains and regenerate the provisioning profile.
3. **Supabase dashboard, staging then production:** Authentication, Passkeys, enable; Relying Party Display Name `Lumen`; Relying Party ID `lumen.trigo.workers.dev`; Origins `https://lumen.trigo.workers.dev`.
4. **Deploy the two early web pieces**, before iOS submission, from the same checkout:

   ```bash
   npm ci
   npm run build                                   # produces the stylesheet the page uses
   npx vite-node scripts/build-release1-site.tsx   # writes dist-release1/ (not committed)
   cd dist-release1
   npx wrangler deploy --dry-run                   # read what it says it will upload
   npx wrangler deploy
   ```

   `dist-release1/` holds a Worker named `lumen` whose only content is static: `/privacy`, `/.well-known/apple-app-site-association` with `_headers` (so it is served as `application/json`), and one stylesheet. Every other path, including `/` and `/security`, returns 404. It does not include the web app, its server code or any Supabase call. Checked locally with `wrangler dev` on 2026-11-18: `/privacy` 200, the AASA file 200 `application/json`, `/security` and `/` 404.
   - The deploy name `lumen` is what makes the host `lumen.trigo.workers.dev` **(unverified: it assumes your Workers subdomain is `trigo` and the name `lumen` is free; `wrangler deploy --dry-run` and the Cloudflare dashboard show the final URL)**.
   - The main app's `wrangler.jsonc` is named `tanstack-start-app`. If you later deploy the full web app to the same host, give it `--name lumen` on purpose, since that replaces this static site.
5. **Check the deployed host** (Apple's CDN caches the AASA file, so fix it before submitting):

   ```bash
   curl -sSI https://lumen.trigo.workers.dev/.well-known/apple-app-site-association   # 200, application/json, no redirect
   curl -sSI https://lumen.trigo.workers.dev/privacy                                  # 200
   curl -sSI https://lumen.trigo.workers.dev/security                                 # 404 for release 1
   ```

6. **Passkey builds** pass `--dart-define=PASSKEYS_ENABLED=true` (CI release build already does; a hand-built archive needs it).

## 5b. Point a build at the target

- **Staging (LM-120):** a TestFlight or simulator build pointed at staging.
- **Done when:** the post-migration check passes, a session closes without a 503, and a test account can sign up, talk, forget someone (beta), add and use a passkey, and delete itself, with a second account untouched.
- **Production (LM-125):** iOS ships after the migrations, edge functions and `cdk deploy` are live on production. The full web app is not part of release 1.

## 6. Production: repeat

Run sections 0 to 4 again (section 5 steps 3 to 5 for production Passkeys; the early site is one deploy, not per project) with:

```bash
export REF=bjoevzvsdlhlcjywpyfx
```

and the production AWS and Supabase logins. Backup first (section 1). The same file table applies. For each command that names a ref, the flag is `--project-ref bjoevzvsdlhlcjywpyfx`, for example:

```bash
supabase functions deploy delete-account --project-ref bjoevzvsdlhlcjywpyfx
```

Record, for each step on each project, the date and what you saw.

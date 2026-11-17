# Release 1 deploy runbook (LM-120 staging, LM-125 production)

One page, the same order twice. Run it on **staging** first (LM-120). Run it again on **production** (LM-125) only after LM-120 to LM-124 pass. It is built from `launch-checklist.md` section 2 plus the release 1 changes: the new `delete-account` function, the deleted `extract-graph` edge function, the LM-102/103 migration, and passkeys.

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
| 19 | **`<FILL IN AFTER LM-128 MERGES>`** (the LM-102 migration; run `ls supabase/migrations` and copy the new file name here, in file-name order, which may be after #18) | LM-102/103 |
| 20 | **`<FILL IN IF ANY>`** any other migration that LM-114 to LM-117 or LM-127 added (none expected; confirm with `ls supabase/migrations`) | |

Why this order: `…300` drops LM-46's caps and `…700` restores them, so a partial run leaves the caps off. `…200000` must be live before the iOS build ships. The new `close-session` code calls an RPC from `…300`, so migrations go before the Lambda or every session close returns 503.

### Post-migration check (do not go on if either fails)

On the target project, as a test user (never a real one):

1. An oversized card call to `save_session_card` is **refused**.
2. A card naming a forgotten person is stored **redacted**.
3. A card mentioning a merely removed word is stored **unchanged**.
4. `supabase migration list` shows every file in the table as applied on the Remote side.

## 3. Edge functions

Deploy after the migrations. All with `--project-ref "$REF"`.

```bash
supabase functions deploy embed-entities  --project-ref "$REF"
supabase functions deploy retrieve-memory --project-ref "$REF"
supabase functions deploy speak-agent     --project-ref "$REF"
supabase functions deploy delete-account  --project-ref "$REF"
```

- `delete-account` is new in release 1 (LM-114). Its secrets (the Supabase service key it reads from its environment, and the Sign in with Apple key, key id and team id from LM-115) are set in the dashboard or with `supabase secrets set`, never in the repo or on a command line you keep in shell history. **<FILL IN the exact secret names once LM-115 merges>**.
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

## 5. Point a build at the target

- **Staging (LM-120):** a TestFlight or simulator build pointed at staging.
- **Done when:** the post-migration check passes, a session closes without a 503, and a test account can sign up, talk, forget someone (beta) and delete itself, with a second account untouched.
- **Production (LM-125):** iOS ships after steps 1 to 4 are live on production. The web app (with `/privacy` and `/security`) ships only after the iOS release, except `/.well-known/apple-app-site-association` for passkeys (LM-127), which must be served before the iOS build.

## 6. Production: repeat

Run sections 0 to 4 again with:

```bash
export REF=bjoevzvsdlhlcjywpyfx
```

and the production AWS and Supabase logins. Backup first (section 1). The same file table applies. For each command that names a ref, the flag is `--project-ref bjoevzvsdlhlcjywpyfx`, for example:

```bash
supabase functions deploy delete-account --project-ref bjoevzvsdlhlcjywpyfx
```

Record, for each step on each project, the date and what you saw.

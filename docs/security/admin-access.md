# Admin access and break-glass (LM-45)

Status: written for one developer today, structured so a second person can be added without rewriting it.

Items marked **(unverified)** describe vendor features or settings that were not checked against the live consoles or the project's plan when this was written. Check them before relying on them, then remove the marker.

## What this does and does not do

This limits access to production data by rule and by logging. It does **not** technically stop an owner of the Supabase project or the AWS account from reading user data. Anyone holding the Supabase owner login, the service-role key or AWS admin can read journals today. Only the end-to-end encryption work in Phase 3 changes that. Until then, do not tell users "we can't read it".

## Who can reach production data

Production Supabase project ref: `bjoevzvsdlhlcjywpyfx`.

| Path | What it reaches | Who has it today | Controls |
|---|---|---|---|
| Supabase dashboard (Table editor, SQL editor) | Every user table, RLS bypassed (runs as `postgres`) | Org owner (the developer) | MFA on the org; the SQL rule below; no standing second member |
| Supabase personal access token (`SUPABASE_ACCESS_TOKEN`, used by the staging workflow and the CLI) | A personal access token acts as the account that created it. It can use the Management API, including running SQL, on **every project that account can reach, production included**, not only the one the workflow targets. This is the real risk behind the staging workflow | Whoever can read the GitHub secret, plus the account owner | Use a token created by a separate account that is a member of the staging project only (or a scoped token, if the dashboard offers scoping: unverified); never the owner's own token. Rotate it (table below) |
| Production database password (`SUPABASE_DB_PASSWORD`, direct `postgres` connection) | Full superuser-level SQL over a direct connection, RLS bypassed, and it works without going through the dashboard or its session/MFA | The owner; anything that stores it (password manager, shell history, `.env`, GitHub secret) | Keep it only in the password manager; never in GitHub for production (the staging workflow needs staging's only); rotate it (table below); restrict network access if the plan offers it (unverified) |
| Supabase backups and PITR | Every row of every table. Per Supabase's docs, daily backups are kept 7 days (Pro) or 14 (Team), and PITR is a paid add-on of 7, 14 or 28 days; both restore from the dashboard or Management API. Whether a backup can be downloaded, who may do so, and whether backups are encrypted: unverified | Anyone with dashboard owner access | Same as dashboard access; never download or restore a production backup to a laptop or staging (rule 4); deleting a user's data does not remove it from backups until they age out, so privacy copy must not promise instant erasure (unverified retention for this plan) |
| Supabase service-role key | Same as above via API, RLS bypassed | Whoever can read edge function secrets, the Supabase API settings page, or the GitHub secret below | Rotation (checklist below); not in the repo or the app bundle |
| Supabase edge functions that use the service-role key | See next table | Code in `supabase/functions` | Deployed by the owner only |
| AWS Secrets Manager `echo-insights/gemini-api-key` | The Gemini key (can spend money and call Gemini as Lumen; it does not give database access) | AWS root/IAM admins; the four Lambdas that call `GetSecretValue` | IAM least privilege (`grantRead` per Lambda in `infra/lib/infra-stack.ts`); MFA; CloudTrail |
| AWS Lambda configuration | Environment values `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` (public, anon-level) and the secret ARN | AWS admins | MFA; CloudTrail |
| CloudWatch Logs for the Lambdas and API Gateway | Request metadata. Must hold no journal content (global rule); see "Honest limits" | AWS admins | MFA; log-content rule enforced in code review |
| DynamoDB `GraphExtractionCache` | A cache for extraction results. It may contain derived content, so treat it as user data (confirm what is stored: unverified) | AWS admins | MFA; TTL on `expiresAt` |
| GitHub repo secrets and the `staging` environment | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `EMBED_INTERNAL_SECRET` (names from `.github/workflows/flutter-retrieval-release.yml`) | Repo admins; any workflow that runs on a branch able to read the `staging` environment | MFA on GitHub; keep these values for the **staging** project only (see note below) |
| Supabase Vault (inside the database) | `embed_internal_secret`, `embed_entities_url` (per `supabase/migrations/20260705000002_embed_config_vault.sql` and `docs/guide/getting-started.md`) | Anyone with SQL access | Same as dashboard SQL |

### Where the service-role key is actually used (from the repo)

No AWS Lambda uses a Supabase service key. They call Supabase with the signed-in user's own token plus the publishable key (`infra/lambda/*/index.mjs` read `SUPABASE_PUBLISHABLE_KEY`; `infra/lib/infra-stack.ts` passes only `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `GEMINI_SECRET_ARN`).

`SUPABASE_SERVICE_ROLE_KEY` appears in exactly two edge functions:

| Place | Why | Notes |
|---|---|---|
| `supabase/functions/embed-entities/index.ts` | Reads a notebook's entities and writes embeddings | `verify_jwt = false`; gated by the `x-internal-secret` header (`EMBED_INTERNAL_SECRET`), so that secret is as sensitive as the service key |
| `supabase/functions/retrieve-memory/index.ts` | Admin client for the server-only vector match (`match_*_entity_embeddings` is granted to `service_role` only) | The user path uses the anon key plus the caller's token |

Other places the name appears:

- `src/integrations/supabase/client.server.ts` (web app admin client). It reads `SUPABASE_SERVICE_ROLE_KEY` from the server environment, but nothing in `src/` imports it today. If the web app is deployed (`wrangler.jsonc` suggests Cloudflare), check that host's environment for a copy of the key (unverified) and remove it if unused.
- `.github/workflows/flutter-retrieval-release.yml`, `scripts/retrieval-release-gate.mjs`, `test_release/retrieval_release_gate_test.dart`: fixture setup against **staging** only.
- `public.conversation_runtime(text, jsonb)` is executable by `service_role` only (`supabase/migrations/20260917000000_conversation_runtime.sql`). Nothing in `lib/`, `src/`, `infra/` or `supabase/functions` calls it, so it is reachable only by someone holding the key.
- `scripts/production-secrets.mjs` scans the iOS build for these names so they never ship in the app.

Other server-side secrets that exist: `GROQ_API_KEY` (edge function `extract-graph`), `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID`, `ELEVENLABS_OUTPUT_FORMAT` (edge function `speak-agent`). Whether these functions are still deployed or used is unverified. They are third-party keys, not database access, but they are in the same dashboard.

Note on the GitHub workflow: `SUPABASE_PROJECT_REF` is a repo/environment variable and the workflow runs `supabase db push --linked --yes` and deploys functions against it. It checks that the URL matches the ref, not that the ref is staging. Confirm the variable in the `staging` environment is a staging project and not `bjoevzvsdlhlcjywpyfx` (unverified). The service-role key stored there must belong to that same staging project.

## Rules

1. **No dashboard SQL against user tables in production.** That means no `select`, `update` or `delete` on user-owned tables (notebooks, entities, cards, sessions, briefs, embeddings, and anything added later) from the SQL editor, the table editor, `psql` or a script, except through break-glass below. Schema changes go through migrations, applied by the owner, and tested locally first.
2. **Allowed without break-glass:** the dashboard's usage and health views, function logs that contain no content, `supabase test db` against the local stack, and migrations. Schema introspection (`information_schema`, `pg_catalog`) is fine.
3. **Staging and local use synthetic data only.** Seed with generated data (`supabase/tests` fixtures or a seed script). Never sign in to staging with a real person's account or import a real journal.
4. **No production rows copied anywhere.** Not to staging, local, a spreadsheet, a ticket, a chat, a screenshot, a gist, an AI prompt or a log. No `pg_dump` of user tables. If a bug can only be reproduced with real data, reproduce the shape with synthetic data instead.
5. **No journal content in logs, errors or analytics** (global rule). If a debug session finds content in a log, treat it as an incident under break-glass step 6.
6. **Secrets never go on a command line, in the repo or in chat.** Paste them only into the console or secret store field that holds them.

## Break-glass runbook

### Who may use it

Today: the project owner (the developer), acting alone. When a second person exists, the owner approves and the second person acts, or two people are present; the person who acts is never the only person who knows it happened.

### What justifies it

Only one of these:

- A real incident: data loss or corruption, a suspected breach, a production outage that cannot be diagnosed from metadata and logs.
- A request from a user about their own data (an export or a deletion they asked for that the app cannot complete), made by that user through a channel you can tie to them.

Not justified: curiosity, "checking a few journals", product analytics, demo data, testing with real data, a request from anyone other than the data's owner (including law-enforcement style requests; handle those separately and legally).

### Steps

1. **Write the reason first.** Before touching anything, open a new entry in the access log (a private note or a private repo issue, not a public one) with: date and start time, who, which of the two justifications, the incident or user-request reference (a ticket id, not the user's name or email in the repo), the narrowest scope needed (which table, which user id, which question), and the planned end time. Keep user identifiers out of the repo; store them in the private note only.
2. **Set the time limit.** Decide the window in advance (default 1 hour, maximum one working day). Set a calendar alarm for the end. Neither Supabase nor this repo provides automatic expiry of the owner's access (unverified for the Supabase plan in use), so the time limit is enforced by the alarm and by step 5.
3. **Get access the narrowest way available.**
   - Prefer a read-only SQL statement scoped to one user id, run in the Supabase dashboard SQL editor, over the service-role key. The editor runs as a privileged role; take only the columns needed.
   - Do not reveal or copy the service-role key for this. If the key must be used (for example to run an API call that only it can make), use it from your own machine for the window and rotate it at step 5.
   - If AWS data is needed (a secret or logs), assume the IAM role or user with MFA and, if a role exists, a short session (1 hour). The repo defines no break-glass IAM role; creating one is a user action (unverified whether one exists in the account).
   - With a second team member, give them the minimum Supabase org role for the window and remove it at step 5. Supabase org roles and which are available on the project's plan: unverified.
4. **Do the work, minimally.** Look only at what the scope in step 1 names. Do not copy rows out; record counts, ids and outcomes, not content. For a user-requested export, deliver it only to that user through the app or a verified channel and delete your copy.
5. **Close access.**
   - End the dashboard session; remove any temporary org member or role.
   - If the service-role key was displayed, copied or used outside the platform, rotate it using the rotation order below and record the date.
   - If a temporary IAM user, role or access key was created, delete it.
   - Clear local copies (query results, clipboard, terminal scrollback).
6. **Record the outcome.** In the same log entry add: end time, what was run (statement text with parameters redacted of content), how many rows were read or changed, whether any content reached a log or a note (if so, delete it and note that), and follow-ups. Review the log monthly.

### What is logged, and where

| Source | What it shows | Retention / limits |
|---|---|---|
| Supabase dashboard "Logs" (API, Postgres, edge function logs) | API requests, Postgres logs and edge function output. Query text only appears if statement logging is enabled for the project | Retention depends on plan (unverified, commonly days not months). Export a copy of the relevant slice to the access log entry at step 6 (metadata only) |
| Supabase organization audit logs | Dashboard actions by org members such as member changes and some settings | Availability depends on plan tier (unverified). If the plan lacks it, the written access log in step 1 is the only record of dashboard SQL |
| Postgres statement logging / `pgaudit` | Individual SQL statements, including those from the SQL editor | Not enabled by this repo (no config in `supabase/`). Whether it can be enabled on the plan is unverified. Until it is, dashboard SQL is **not** reliably logged: the written log is the control |
| AWS CloudTrail | AWS API calls, including `GetSecretValue` on `echo-insights/gemini-api-key`, IAM changes, console sign-ins (with MFA used or not) | CloudTrail Event history keeps recent management events (90 days is the documented default, unverified for this account). The CDK stack in `infra/` creates no trail, so there is no long-term copy. Creating a multi-region trail to a private S3 bucket is a user action |
| CloudWatch Logs (Lambdas, API Gateway) | Invocations, errors and latencies. No content by rule | Today the stack sets no retention, so the default is indefinite. Once LM-44 merges, retention is set to 14 days; update this row then |
| GitHub audit log and Actions history | Secret changes, member changes, workflow runs | The org audit log exists on org plans; for a personal repo, use the repo's Security log and Actions history (unverified which applies) |

To spot use of the Gemini secret by someone other than the app, filter CloudTrail for event name `GetSecretValue` and look for principals other than the four Lambda execution roles.

### If it goes wrong

If you read more than the scope, or any content landed somewhere it should not be (a log, a note, a chat), rotate the service-role key, note the event in the log, and if a user's data was exposed beyond what they asked for, decide on notification separately and promptly.

## User checklist (console actions)

These are done by the owner in the consoles. Nothing in the repo changes them. Keep screenshots of the settings pages in a private note, not in the repo.

### A. MFA and members (do first)

1. Supabase: turn on MFA for your account (Account preferences). Enforce MFA for the organization if the plan offers it (unverified). Confirm in Organization > Team that you are the only member (or each other member is needed and has the lowest sufficient role). Remove stale invitations.
2. AWS root: enable MFA (a hardware key or passkey if possible). Do not use root day to day. Delete any root access keys.
3. AWS IAM: enable MFA for every IAM user (or use IAM Identity Center with MFA). Remove unused users and access keys. Add an IAM policy condition requiring MFA for admin actions if you keep long-lived IAM users (unverified whether this exists).
4. GitHub: turn on 2FA for your account (passkey or security key). For an organization, require 2FA in the org settings. Review collaborators, deploy keys, and the Actions secrets list; remove what is unused.
5. Org and repo membership: keep it to the people who must have it. Review quarterly and on every departure.

### B. Rotation order

Do the Gemini key first (it has no database access and is simplest), then the Supabase key. The Gemini rotation is a quick single sitting. The Supabase one is not: read its section first, because rotating the legacy key is an outage.

**1. Gemini key (`echo-insights/gemini-api-key`)**

1. In the Google console that issued the current key (AI Studio or Google Cloud, wherever it was created), create a **new** key. Do not delete the old one yet.
2. In the AWS console, open Secrets Manager > `echo-insights/gemini-api-key` > Retrieve/edit > "Set new value" (plaintext), paste the new key, save. Do not use the command line for this.
3. What must be updated in AWS: nothing else. None of the four handlers that read the secret (`infra/lambda/live-session/index.mjs`, `infra/lambda/close-session/index.mjs`, `infra/lambda/close-session/brief-index.mjs`, `infra/lambda/extract-graph/index.mjs`) caches it: each calls `GetSecretValue` on every call, so the new value is used immediately. No redeploy or env change is needed. Locally, update or delete any copy of the old key in a `.env` file on your machines (`test/gemini_live_probe.dart` reads `GEMINI_API_KEY` from `.env`; `.env` is gitignored, so it is not in the repo, but it is on disk). The secret has a RETAIN removal policy, so a stack update does not delete it.
4. Verify (below), then delete the old key in the Google console.
5. Check the Google console for use of the old key during the gap; unexpected use means it leaked earlier.

**2. Supabase service key**

What the docs say (checked against Supabase's API-keys and Edge Function secrets pages at the time of writing):

- Secret keys (`sb_secret_...`) and the legacy `service_role` JWT key both map to the `service_role` Postgres role and both bypass RLS. Creating a new secret key does **not** revoke the legacy key. Both stay valid until you disable the legacy keys in the dashboard's API Keys settings.
- Edge functions are injected with `SUPABASE_SERVICE_ROLE_KEY` carrying the **legacy** key (and also `SUPABASE_SECRET_KEYS`, a JSON dictionary of the project's secret keys). Names starting with `SUPABASE_` are reserved: you cannot set your own secret with that prefix.

What follows from that for this repo:

- `embed-entities` and `retrieve-memory` read `Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")`. Creating a new `sb_secret_` key and deleting an old `sb_secret_` key therefore rotates **nothing these functions use**, and the legacy key they do use stays valid.
- To actually revoke the key the functions use, the legacy JWT keys must be rotated or disabled. To move the functions to a new `sb_secret_` key, the code must read it from `SUPABASE_SECRET_KEYS` or from a custom-named secret (not `SUPABASE_`-prefixed). That is a code change, out of scope for LM-45; open a follow-up ticket for it.

**Recommended path: migrate first, then rotate.**

1. Follow-up code change (separate ticket): functions read a named key from `SUPABASE_SECRET_KEYS` (or a custom secret), the staging workflow and any web host use `sb_secret_` keys, and the app and Lambdas use the new publishable key. Deploy and verify.
2. Only then disable the legacy keys in the dashboard (this is what actually kills the old service key).
3. Create any new `sb_secret_` keys per component (separate keys for separate backends, so a leak means rotating one), and rotate those by creating a new key, updating its one consumer, then deleting the old one.

**If you must rotate the legacy key before the migration (not recommended).** Rotating the legacy JWT secret is an outage, not a quick change. Whether it changes the legacy anon key as well is not stated on the pages checked (unverified); assume it does, because both are signed with the same secret. If so:

- The anon key compiled into every shipped app build (`SUPABASE_ANON_KEY` dart-define) stops working until a new app build is released and installed. Users on the old build cannot read or write data.
- `SUPABASE_PUBLISHABLE_KEY` in all five Lambdas (set from the `SupabasePublishableKey` CloudFormation parameter) stops validating tokens and calls until a CDK deploy supplies the new value, so the voice broker, extraction, closing card and brief all fail.
- Existing user sessions may be invalidated and require sign-in (unverified).
- Plan a maintenance window, prepare the new app build and the CDK parameter first, and accept that the app is down for users on older builds. This is why migrating first is recommended.

After any Supabase key change, update every place that holds the affected value:

| Place | How | Notes |
|---|---|---|
| Edge function secrets (`embed-entities`, `retrieve-memory`) | The functions read the injected legacy `SUPABASE_SERVICE_ROLE_KEY`; you cannot override it (reserved prefix). Secret changes take effect without redeploy, per the docs, but this one is platform-injected: confirm in a test call that the function sees the new value after a legacy rotation, and redeploy from the dashboard if it does not (unverified) | Do not rely on a "manual override secret": it is not possible under that name |
| GitHub `staging` environment secret `SUPABASE_SERVICE_ROLE_KEY` | Must be the **staging** project's key. Rotate staging separately | If it holds the production key, replace it now |
| Web host environment (if deployed) | Update or delete `SUPABASE_SERVICE_ROLE_KEY` there | Nothing in `src/` currently needs it |
| `EMBED_INTERNAL_SECRET` | See the order below | Rotate with the service key only if it was exposed |
| Anon/publishable key (legacy JWT rotation only) | `SupabasePublishableKey` CDK parameter (owner's own deploy), the app's `SUPABASE_ANON_KEY` build define, the GitHub `SUPABASE_ANON_KEY` secret, and edge function `SUPABASE_ANON_KEY` (injected) | Needs a CDK deploy and a new app build |

Not needed: Lambdas for the service key (they do not use it).

**Rotating `EMBED_INTERNAL_SECRET`**

The same value lives in edge function secrets (`EMBED_INTERNAL_SECRET`), in Supabase Vault as `embed_internal_secret` (the database trigger and the cron sweep send it as `x-internal-secret`), and in the GitHub `staging` secret (the release gate). Order:

1. Generate a new long random value in your password manager. Never put it on a command line.
2. Update the edge function secret `EMBED_INTERNAL_SECRET` first (takes effect without a redeploy, per the docs). From this moment the database's old value is rejected with 403 by `embed-entities`.
3. Immediately update Vault in the SQL editor with `vault.update_secret` on the secret named `embed_internal_secret` (look up its id in `vault.secrets` by name; this is a statement on config, not a read of user tables, and does not need break-glass, but never `select` the decrypted value into a note).
4. Update the GitHub `staging` secret for the staging project.
5. Recovery from a mismatch: between steps 2 and 3, new entity inserts that fire the trigger are rejected and no embedding is written. `embed_reconcile_sweep` (`supabase/migrations/20260705000002_embed_config_vault.sql`) runs on a cron and re-posts every notebook that has entities, so it heals that window once Vault holds the new value. If the sweep or the cron job is not running, run `select public.embed_reconcile_sweep();` once after step 3. If a step-3 typo left Vault empty, the trigger and sweep skip silently (they return when the secret is empty), so check that a new entity gets an embedding.

**3. Verify the app still works after each rotation**

- After the Gemini key: start a voice session from a test account (the Lambda `live-session` path), then end it (close card and brief paths use the same secret). Check CloudWatch for `live-session`, `close-session` and `extract-graph` errors in the last 15 minutes: expect none.
- After the Supabase key: sign in, open the journal and graph (reads), write a new entry so the embedding trigger runs `embed-entities`, then ask Lumen a question that triggers memory retrieval (`retrieve-memory`). Check the Supabase function logs for 401/403 and for `embed-entities stage=` errors.
- Run the GitHub "Flutter retrieval release gate" workflow against staging to confirm CI still authenticates with its own staging key.
- Use a test account with synthetic data, never a real person's journal.

**4. Rotation record**

Update this table in a private note and commit only the dates here if you want them tracked in the repo (dates are not sensitive).

| Credential | Last rotated | Next due | Rotated by | Notes |
|---|---|---|---|---|
| Gemini key (`echo-insights/gemini-api-key`) | | | | Rotate every 6 months or after any exposure |
| Supabase service key (production) | | | | Rotate every 6 months, after any break-glass use of the key, or after any exposure |
| `EMBED_INTERNAL_SECRET` / Vault `embed_internal_secret` | | | | With the service key if exposed |
| Supabase personal access token (`SUPABASE_ACCESS_TOKEN`) | | | | Revoke the old token in the account settings after the new one works; prefer a separate staging-only account |
| Production database password (`SUPABASE_DB_PASSWORD`) | | | | Reset in Project settings > Database; update the password manager and anything that used it (staging has its own) |
| Legacy Supabase JWT keys | | | | Not rotated until the migration ticket lands; then disable rather than rotate |

## Honest limits

- This is rule-based. The owner can still read any row, and nothing in the stack technically prevents it. Logging detects some use after the fact; it does not stop it.
- Dashboard SQL may not be logged at statement level (see the log table). If so, the written access log is the only record, and it depends on you writing it.
- Time limits are procedural for a solo owner. They become real only when access is granted to a second person and revoked.
- Supabase and AWS are vendors who hold the data as well (databases, backups, logs, Secrets Manager). Their staff and systems can in principle reach it under their own policies; nothing here constrains them. Only Phase 3 encryption would.
- Backups outlive deletes until they age out of retention.
- Service-role key and Gemini key rotation limits the window for a leaked key; it does not remove your own access.
- Technical enforcement (not even the operator can read journals) arrives with the Phase 3 encryption work. Privacy copy must not claim otherwise before then.

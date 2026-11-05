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
| CloudWatch Logs (Lambdas, API Gateway) | Invocations, errors and latencies. No content by rule | Default retention is indefinite unless set; setting a finite retention is a user action (the stack does not set it) |
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

Do the Gemini key first (it has no database access and is simplest), then the Supabase key. Do each in one sitting so the app is never left with a half-updated set.

**1. Gemini key (`echo-insights/gemini-api-key`)**

1. In the Google console that issued the current key (AI Studio or Google Cloud, wherever it was created), create a **new** key. Do not delete the old one yet.
2. In the AWS console, open Secrets Manager > `echo-insights/gemini-api-key` > Retrieve/edit > "Set new value" (plaintext), paste the new key, save. Do not use the command line for this.
3. What must be updated: nothing else. The Lambdas read the secret on each call (see `getPermanentCredential` in `infra/lambda/live-session/index.mjs`; the other handlers follow the same pattern, confirm none caches the value across invocations). No redeploy or env change is needed. The secret has a RETAIN removal policy, so a stack update does not delete it.
4. Verify (below), then delete the old key in the Google console.
5. Check the Google console for use of the old key during the gap; unexpected use means it leaked earlier.

**2. Supabase service key**

Two cases; check which your project uses in Supabase > Project settings > API Keys (unverified which applies):

- *Secret API keys (`sb_secret_...`)*: create a new secret key, update the places below, then delete the old one. The publishable key and user sessions are unaffected.
- *Legacy JWT keys (`service_role` JWT)*: the service-role key is tied to the project's JWT secret. Rotating the JWT secret also changes the anon key and signs every user out. In that case also update the places that hold the anon/publishable key (listed below) and expect users to sign in again. Prefer migrating to the new key types over rotating the legacy secret if the project offers it.

After creating the new key, update every place that holds it:

| Place | How | Notes |
|---|---|---|
| Supabase edge function secrets (`embed-entities`, `retrieve-memory`) | The platform injects `SUPABASE_SERVICE_ROLE_KEY` itself. Confirm in Edge Functions > Secrets that it shows the new value, or redeploy the two functions from the dashboard if it does not (unverified whether a redeploy is required). Redeploy is a deployment, so do it yourself, not via this repo's tooling | Check that you did not previously set a manual override secret |
| GitHub `staging` environment secret `SUPABASE_SERVICE_ROLE_KEY` | Only if it holds the production key. It should hold the **staging** project's key. Rotate staging's key the same way if it is also being rotated | |
| Web host environment (if deployed) | Update or delete `SUPABASE_SERVICE_ROLE_KEY` there | Nothing in `src/` currently needs it |
| `EMBED_INTERNAL_SECRET` and Vault `embed_internal_secret` | Rotate at the same time if the key was exposed: set a new random value in edge function secrets, GitHub, and Vault together | A mismatch breaks embedding triggers |
| Anon/publishable key (legacy JWT case only) | Update the AWS Lambda parameter `SupabasePublishableKey` (CloudFormation parameter in `infra/lib/infra-stack.ts`, applied by the owner's own deploy), the app's `SUPABASE_ANON_KEY` build define, edge function `SUPABASE_ANON_KEY` if overridden, and the GitHub `SUPABASE_ANON_KEY` | Needs an app build and a CDK deploy |

Not needed: Lambdas for the service key (they do not use it).

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
| GitHub `SUPABASE_ACCESS_TOKEN` | | | | Personal access token; rotate yearly |

## Honest limits

- This is rule-based. The owner can still read any row, and nothing in the stack technically prevents it. Logging detects some use after the fact; it does not stop it.
- Dashboard SQL may not be logged at statement level (see the log table). If so, the written access log is the only record, and it depends on you writing it.
- Time limits are procedural for a solo owner. They become real only when access is granted to a second person and revoked.
- Service-role key and Gemini key rotation limits the window for a leaked key; it does not remove your own access.
- Technical enforcement (not even the operator can read journals) arrives with the Phase 3 encryption work. Privacy copy must not claim otherwise before then.

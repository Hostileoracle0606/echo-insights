# Account Deletion Queue (follow-up to LM-114..117) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the synchronous `auth.admin.deleteUser` in `delete-account` with a server-side deletion queue so a lost reply cannot strand a person, purge the auth audit log with the account, and run pgTAP in CI.

**Architecture:** `delete-account` verifies the JWT, revokes Apple (in-request), inserts an idempotent row into `account_deletion_requests` and replies "queued". A pg_cron job calls a SECURITY DEFINER SQL function every minute that deletes users whose request is older than 5 minutes (idempotent, retried until it succeeds). The phone keeps a "deletion pending" marker and wipes local data only after the server answers "queued" (or its session is already gone).

**Tech Stack:** Postgres (pgTAP, pg_cron), Deno edge function, Flutter/Riverpod, GitHub Actions.

**Spec:** the message from the parent session (user choices: queue, audit-log purge, pgTAP CI job); builds on `docs/superpowers/plans/2026-11-17-account-deletion.md` and its results file.

## Global Constraints

- Commit locally only. Never push, deploy, touch a hosted Supabase project, or put keys on a command line. No `pubspec.lock`, `ios/Podfile.lock`, `docs/assets` in commits (restore them after flutter runs).
- Do not edit `docs/release-1-tickets.md`, `docs/security/*`, `src/routes/privacy.tsx`.
- Migration timestamps only from `20261118000100` to `20261118000400` (another session uses `2026111800050x`).
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- `account_deletion_requests` holds no email, no IP, no free text from users: `last_error` is a SQLSTATE code only. It has NO foreign key to `auth.users` (it must outlive the user).
- No log line, warning, or UI text carries a token, Apple code, user id, or server error body.

## Rulings (recorded)

- **Worker = pg_cron calling a SECURITY DEFINER SQL function** (not cron invoking the edge function): no service key or HTTP hop in the database, the cascade + `flow_state` + audit purge + completion mark happen in one transaction, retry is the next minute's tick, and it is testable in pgTAP by calling the function.
- **Delay = 5 minutes** (`requested_at <= now() - interval '5 minutes'`): the app refreshes its session and retries within that window, and a retry after a lost reply still finds a valid user (the JWT/`iat` check and the idempotency row both still work).
- **Audit-log purge lives in the existing `BEFORE DELETE` trigger on `auth.users`** (`purge_deleted_user_rate_limits`), best-effort with a warning like `flow_state`, so every deletion path (the worker, and a direct delete in pgTAP) runs it.
- **Phone side:** the marker implies the person asked for deletion, so a resend that finds its session gone (refresh fails with an auth error) is treated as "deleted": wipe and sign out. A network error keeps the marker. A resend carries no Apple code (the code is single-use, 5 minutes); if the first request never reached the server, Apple is not revoked and the person sees the Settings, Apple ID steps.

## Review Focus

- Same `request_id` twice -> second reply `already_queued:true`, no second Apple revoke, one row (Task 2).
- Worker run twice, and for a user already gone -> no error, request marked completed (Task 1).
- Worker error for one user does not stop the others and sets `last_error` to a SQLSTATE only (Task 1).
- Local data is never wiped before a "queued" answer; a lost reply keeps the marker (Task 3).
- The deletion guard still passes with the request table exempted on purpose and the audit rows purged (Task 1).

---

### Task 1: Tables, worker, audit purge, pgTAP

**Files:**
- Create: `supabase/migrations/20261118000100_account_deletion_requests.sql`, `supabase/migrations/20261118000200_account_deletion_worker.sql`, `supabase/tests/database/account_deletion_queue_test.sql`
- Modify: `supabase/tests/database/deletion_guard_test.sql`

**Interfaces (Tasks 2, 3 rely on these exact names):**
```sql
public.account_deletion_requests(
  user_id uuid not null,            -- no FK
  request_id uuid not null,
  requested_at timestamptz not null default now(),
  completed_at timestamptz,
  attempts int not null default 0,
  last_error text,                  -- SQLSTATE only
  primary key (user_id, request_id));
-- RLS on; policy: authenticated may select rows where user_id = auth.uid(); no insert/update/delete for app roles.
public.process_account_deletions(p_delay interval default '5 minutes', p_limit int default 20) returns int  -- security definer, set search_path = ''; returns rows completed; execute revoked from public, anon, authenticated
```
Cron job `process-account-deletions` every minute, created in a `do` block only when `pg_cron` is available (`pg_available_extensions`), so local/CI stacks without it still migrate.

- [ ] Step 1: tests first. `account_deletion_queue_test.sql` (pgTAP, begin/rollback): `due request deletes the user and every row of theirs, marks completed_at`; `request younger than the delay is not processed`; `a second run is harmless (returns 0, no error)`; `user already gone -> request completed, no error`; `a bystander user and their rows are untouched`; `an exception for one user (force one, e.g. a temp trigger that raises on that user) sets last_error to a 5-char SQLSTATE, attempts+1, and the next user is still processed`; `RLS: an authenticated user sees only their own request rows` (use `set local role authenticated` + `request.jwt.claims`); `the request row outlives the user (no FK)`. Extend `deletion_guard_test.sql`: exempt `account_deletion_requests` from the "user_id means user-owned" check with a comment saying why, and seed `auth.audit_log_entries` rows for U and V (payload `{"actor_id":"<uid>","actor_username":"x","action":"login","log_type":"account"}` and a row where the uid appears in `payload->'traits'->>'user_id'`) asserting U's are gone and V's remain after deleting U; bump `plan(...)`.
- [ ] Step 2: run on a throwaway Postgres built from this worktree's migrations (do NOT use the shared stack on port 55322; remove the container after) — expect FAIL.
- [ ] Step 3: write the migrations: table + RLS + index on `(requested_at) where completed_at is null`; worker function (`for update skip locked`, per-user subtransaction `begin ... exception when others`, `delete from auth.users where id = r.user_id`, mark all open requests of that user completed); cron schedule in a guarded `do` block; `create or replace` of `purge_deleted_user_rate_limits()` adding a best-effort `delete from auth.audit_log_entries where payload->>'actor_id' = old.id::text or payload->'traits'->>'user_id' = old.id::text` in its own exception block (warning text carries no user id), keeping every existing statement, the `security definer`, `search_path`, revoke and comment; update the function comment.
- [ ] Step 4: tests pass; run the full database suite on the throwaway container and record counts.
- [ ] Step 5: commit `feat(db): account deletion queue, worker and audit-log purge`.

---

### Task 2: `delete-account` queues instead of deleting

**Files:** Modify `supabase/functions/delete-account/handler.ts`, `index.ts`, `handler.test.ts`

**Interfaces:**
- Consumes: Task 1 table `account_deletion_requests`; existing `Deps`, `createHandler`, `revokeApple`.
- Produces: request body `{"request_id": "<uuid>", "apple_authorization_code"?: string}`; responses: `200 {"queued":true,"already_queued":boolean,"apple_revoked":boolean|null}`, `400 {"error":"bad_request"}` for a missing/invalid `request_id`, `401`, `405`, `500 {"queued":false}`.
- `Deps` gains `queue: { find(userId, requestId): Promise<boolean>; insert(userId, requestId): Promise<"inserted"|"exists"> }` (index.ts implements it with the service-role client: `select` then `insert`; a unique-violation `23505` means `exists`). `deleteUser` is no longer called by the handler.

- [ ] Step 1: update tests first: keep no-JWT / forged / stale / iat-boundary / getUser-throws / 405 / logs tests; replace deletion expectations with queue expectations: `valid JWT + request_id queues exactly the JWT's user (body user_id ignored)`; `missing or non-uuid request_id -> 400, nothing queued, no Apple call`; `same request_id again -> already_queued:true, Apple NOT called again, no second insert`; `a request already queued is found BEFORE Apple is called`; `insert race returning "exists" -> already_queued:true`; `Apple user: revoke runs before the insert, once, with the one-retry policy from apple.ts`; `Apple failure still queues with apple_revoked:false`; `queue insert error -> 500 queued:false`; `deleteUser is never called` (fake admin without deleteUser must not break).
- [ ] Step 2: FAIL; Step 3: implement; keep logging to allowlisted codes only (`stage: "queued"|"already_queued"`), no user id or request id in logs.
- [ ] Step 4: run the full CI deno command (privacy-tests.yml `edge-functions`), expect all green; restore any `deno.lock` change.
- [ ] Step 5: commit `feat(delete-account): queue the deletion instead of deleting inline`.

---

### Task 3: App marker, resend, wipe after "queued"

**Files:** Modify `lib/services/account_deletion_service.dart`, `lib/screens/dashboard/delete_account_screen.dart`, the app startup/bootstrap file that already runs per-launch work (find it; follow how other launch sweeps are wired), their tests; Create a small marker store (`lib/services/deletion_pending_store.dart`) using whatever key-value/secure storage the app already uses for similar small flags.

**Interfaces:**
- Consumes: Task 2 contract (body `request_id`, response `{queued, already_queued, apple_revoked}`), existing `DeleteAccountGateway`.
- Produces: `DeletionPendingStore { Future<String?> read(); Future<void> write(String requestId); Future<void> clear(); }`; `AccountDeletionService.deleteAccount()` now: writes the marker (new uuid) BEFORE the call, then `gateway.call(requestId:, appleAuthorizationCode:)`; on `queued` (new or already) returns the same `DeleteOutcome` values as today, clears the marker, and only then does the screen run signedOutCleanup + sign-out; on failure keeps the marker. New `Future<DeleteOutcome?> resumePending()`: no marker -> null; marker -> `refreshSession` then call with the stored id and no Apple code; queued -> clear marker, sign out local, return `deleted`; refresh/call fails with an auth error (session gone) -> treat as deleted (same wipe); network error/timeout -> keep marker, return null. Launch hook calls `resumePending()` and, on `deleted`, runs `signedOutCleanupProvider` and shows the login notice.

- [ ] Step 1: tests first (service + widget + launch): `request id is generated once and the same id is resent on retry`; `reply lost, retry with the same id gets already_queued and the app wipes`; `marker written before the call and cleared only after queued`; `failure (network) keeps the marker and local data`; `marker is resent on launch and wipes only after the server answers queued`; `on launch with a marker and a dead session the app wipes and signs out`; `on launch with no marker nothing is called`; existing cancel / failed re-auth / Apple-cancel / double-tap / 45 s timeout tests still pass (update their fakes: the gateway `call` takes `requestId`).
- [ ] Step 2: FAIL; Step 3: implement; the real gateway sends `{"request_id": id, "apple_authorization_code": code?}`; never log or show server text.
- [ ] Step 4: run the LM-116 test set (`account_deletion_service_test`, `delete_account_screen_test`, `account_auth_service_test`, `dashboard_test`, `privacy_copy_test`) plus the new launch test and `flutter analyze` on touched files; restore lockfiles.
- [ ] Step 5: commit `feat(app): deletion pending marker, resend on launch, wipe after queued`.

---

### Task 4: pgTAP in CI

**Files:** Modify `.github/workflows/privacy-tests.yml`

- [ ] Step 1: add a job `database-tests` (ubuntu-latest, timeout 20 min): checkout, `supabase/setup-cli@v1` pinned to a specific CLI version (use the version installed locally from `supabase --version`), `supabase start` (exclude services the tests do not need with `-x`, e.g. studio, imgproxy, edge-runtime, logflare, vector, mailpit, if the CLI version supports each), then `supabase test db`, then `supabase stop` in an `if: always()` step.
- [ ] Step 2: validate YAML locally (`python3 -c "import yaml..."` and `actionlint` if installed); confirm the job names and that existing jobs are unchanged. You cannot run it on GitHub; say so.
- [ ] Step 3: commit `ci: run pgTAP (supabase test db) in privacy-tests`.

---

### Task 5: Results file

Update `docs/superpowers/plans/2026-11-17-account-deletion-results.md`: what changed (queue replaces synchronous delete; rulings above), migration file names, test counts from the controller's own final runs, the user step "turn off Write audit logs to the database in the Supabase dashboard (Auth > Settings) so the log stops filling; the purge cleans what exists", the pg_cron requirement (enable the extension on the hosted project, confirm the job runs on staging), the Apple-on-lost-first-request limitation, and corrections to the earlier "lost reply" follow-up (now resolved). Commit.

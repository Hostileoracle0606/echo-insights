# Queued Account Deletion Closeout Plan

**Goal.** Finish LM-114–117, integrate the queue into Release 1, and verify the complete deletion flow on staging.

**Architecture.** The `delete-account` edge function handles Apple revocation during the request and persists the queue entry before acknowledging it. Flutter keeps a retry marker until it can finish local sign-out and cleanup. A Supabase `pg_cron` job runs every minute and processes requests at least five minutes old. The database trigger purges database sign-in audit rows during account deletion.

**Stack.** Flutter, Deno, Supabase Auth, Postgres, pgTAP, GitHub Actions, and Sign in with Apple.

**Source.** `docs/release-1-tickets.md` (LM-114–117) and `docs/superpowers/plans/2026-11-18-account-deletion-queue.md`.

**Starting point.** The deletion worktree is at `7fe1ab1`. The worker locking migration and edits to `account_deletion_queue_test.sql` and `deletion_guard_test.sql` are uncommitted. The local release branch is at `c3a346b`. Run destructive database tests only against an isolated local stack or disposable staging accounts.

## 1. Close out the database changes

- [ ] Review `20261118000300_account_deletion_worker_locking.sql` and the two SQL test diffs together. Check that the worker claims one user at a time, completes all open requests for a deleted user, and can be executed by the scheduled job. Check that normal client roles and `service_role` cannot invoke it.
- [ ] Start a fresh local Supabase stack in an isolated checkout with a distinct project ID and ports. Use the CI-pinned CLI and keep Supabase Auth enabled. Run `supabase test db` and record the CLI/Auth versions, test counts, and exit status. Expect zero failures across the queue, deletion guard, and remaining database suites.
- [ ] Verify overlap with two independent database sessions and two due requests for the same disposable user. Hold the first worker transaction open after calling the worker while the second calls it. The second returns without waiting on that user's work or raising a deadlock. After the first commits, the user is gone, both requests are complete, and a later tick makes no change.
- [ ] Confirm the queue suite covers the five-minute cutoff, a failed attempt that rolls back and retries, continued processing of other users, and preservation of a bystander's rows. Confirm the deletion guard covers both audit payload shapes (`actor_id` and `traits.user_id`) and exercises the WebAuthn rows on a version where those tables exist. A run on an Auth version without the tables leaves passkey coverage for staging.

## 2. Verify the app and edge function together

- [ ] Run the `edge-functions` Deno command from `.github/workflows/privacy-tests.yml`. Check that the authenticated user's request is persisted before `queued: true`, replaying the same request ID returns `already_queued`, and Apple revocation is attempted inside the original request. A failed Apple revoke still queues deletion and returns `apple_revoked: false`.
- [ ] Run `flutter test test/account_deletion_service_test.dart test/delete_account_screen_test.dart test/deletion_resume_launch_test.dart test/supabase_delete_account_gateway_test.dart test/fresh_install_test.dart`. Confirm local data survives a transient failure, a lost reply reuses the same request ID on launch, and cleanup happens after acknowledgement or the pending flow's definitive session-gone result. Check that an edge-function 401 following a successful session refresh preserves local data and the marker. Confirm the Apple failure message gives the manual removal steps.

## 3. Integrate the verified work and run CI

- [ ] Commit the reviewed locking migration and SQL tests on the deletion branch. Record the test results in `2026-11-17-account-deletion-results.md` under a queued-deletion follow-up so the earlier synchronous-flow notes remain dated. Merge into `feat/release-beta-forget` and rerun the database and deletion suites on the merged tree.
- [ ] Replace the placeholder in `docs/security/release-1-deploy-runbook.md` with the migration list from the merged tree. The deletion flow uses the `20261117000000` prerequisite, then `20261118000100` (queue), `20261118000200` (worker and audit purge), and `20261118000300` (worker locking). The LM-128 migration `20261118000500` follows those. Document which queue fields survive deletion and any retention policy supported by the implementation.
- [ ] Push the release branch and open the release PR. Confirm `Privacy tests / database-tests` and `edge-functions` actually run and pass on the PR commit. Capture their run link alongside the local test counts.

## 4. Verify hosted behavior on staging

- [ ] Apply the migrations and deploy `delete-account` from the verified release commit. Configure the Apple credentials for staging and verify that the `process-account-deletions` cron entry is active. Prepare disposable email and Apple accounts plus a bystander. Include existing audit rows for the test users so the purge test has rows to remove, then turn off database audit writes as specified in the runbook.
- [ ] On a real iPhone, request deletion for each disposable account. Verify `queued` acknowledgement precedes local sign-out and cleanup. On the Apple path, confirm the Apple grant is revoked during the request and verify it in Apple Account settings. Check that a forced transient request failure keeps local data and that reopening the app resumes the same deletion.
- [ ] Observe a scheduled run complete each request after it becomes eligible. Confirm that the deleted users' previous sessions fail to refresh, their test content and relevant auth rows are gone, and the bystander can still sign in with their data intact. Include a passkey credential in the deletion fixture when the staging Auth schema supports it.
- [ ] Confirm that both seeded sign-in audit row shapes are gone for the deleted user and that the bystander's existing rows remain. Verify a new test sign-in produces no new database audit row after the switch. Check the retained queue row for `completed_at` and a clear `last_error`. A completed queue row alone cannot verify the best-effort audit purge.
- [ ] Record the release commit, CI link, staging build, and pass/fail for email deletion, Apple revocation, retry, scheduled cleanup, passkeys, and audit purge. Close LM-114–117 once the work is merged and these checks have passed.

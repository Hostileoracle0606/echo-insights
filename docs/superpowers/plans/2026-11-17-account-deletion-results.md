# Account deletion (LM-114..117): results

## Queued deletion follow-up (2026-11-19)

The edge function now answers `queued` after persisting the request. Apple revocation runs in the request, before the queue insert. The phone retains the request ID across a transient failure and resends it on launch. It cleans up after queue acknowledgement or when the pending flow's session refresh confirms the session is gone. The cron job runs every minute and retries requests once they are at least five minutes old.

Apply `20261117000000_account_deletion_flow_state.sql`, then `20261118000100_account_deletion_requests.sql`, `20261118000200_account_deletion_worker.sql`, and `20261118000300_account_deletion_worker_locking.sql` before deploying `delete-account`. The queue retains user and request IDs, request and completion timestamps, the attempt count, and the last failure's SQLSTATE. The migrations set no expiry. The worker attempts to purge `auth.audit_log_entries` and `auth.flow_state` during deletion. Verify both on staging because a failure to purge either table produces a warning and leaves the account deletion committed. Disable database audit writes and verify a new sign-in creates no database audit row.

| Local check | Result |
|---|---|
| Full pgTAP on Supabase CLI 2.75.0, PostgreSQL 17.6, GoTrue 2.186.0 | 34 files, 1,284 tests passed |
| Full pgTAP after starting GoTrue 2.191.0 on the isolated stack | 34 files, 1,284 tests passed, with both WebAuthn tables present |
| Two independent database sessions processing two due requests for one user | Previous worker reproduced SQLSTATE `40P01`. Updated worker skipped the claimed user while the first transaction held the lock, completed both rows once, and did no work on the next tick. |
| Deno CI suite | 98 passed, including 37 deletion and Apple tests |
| Focused Flutter deletion and fresh-install suite | 61 passed |

GitHub Actions and the hosted staging rehearsal are tracked in `2026-11-19-account-deletion-closeout.md`. Verify Apple revocation on a real device. A launch retry carries no Apple authorization code because the code is single-use. If the original request never reached the server, the retry still queues the deletion and the app provides the manual Apple removal steps.

## Original synchronous flow (2026-11-17)

The rest of this report records the earlier synchronous flow and its test results.

## Apple REST API, confirmed

Confirmed 2026-11-17 by reading Apple's live pages in the in-app browser (the pages are client-rendered, so plain fetch returns only titles):
- https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens ("Token validation")
- https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens ("Token revocation")
- https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret (the "Creating a client secret" article; the Sign in with Apple page links to this same article, and the fields are identical)

Confirmed facts:
- Token endpoint `POST https://appleid.apple.com/auth/token`, `application/x-www-form-urlencoded`. Params: `client_id`, `client_secret`, `code`, `grant_type=authorization_code`. The code is single-use and valid five minutes. Response has `access_token`, `refresh_token`, `id_token`, `expires_in`, `token_type`.
- `redirect_uri`: Apple's note says to include it only if the app supplied one in the initial authorization request. A native `getAppleIDCredential` call supplies none, so the function omits it.
- Revoke endpoint `POST https://appleid.apple.com/auth/revoke`, form-urlencoded. Params: `client_id`, `client_secret`, `token` (refresh or access token), optional `token_type_hint` (`refresh_token` or `access_token`). 200 with no body on success, and also if the token was already invalid; 400 with an ErrorResponse otherwise.
- `client_id` is "App ID or Services ID", must match the identifier used in the authorization request, and must not include the Team ID. For the native flow that is the bundle id.
- Client secret: JWT, `alg=ES256` (ECDSA P-256 + SHA-256), header `kid` = 10-character Key ID; claims `iss` = 10-character Team ID, `iat`, `exp` (at most 15777000 s, six months, ahead), `aud=https://appleid.apple.com`, `sub` = the same value as `client_id` (case-sensitive).
- To revoke you need a refresh or access token; Apple says to obtain tokens by validating an authorization code. So the design holds: exchange the fresh code, then revoke. Revoking the refresh token "invalidates the token and associated user authorizations".
- Differences from the ticket's assumptions: none in parameters. The code lives only five minutes, so the app must re-run Sign in with Apple at delete time and send that code at once.

Still not confirmable from docs (needs a device, LM-121): that Lumen disappears from Settings, Apple ID, Sign in with Apple after revoking the refresh token alone, and that a native code exchanges with the bundle id as `client_id` (one forum thread claimed a Services ID was needed; Apple's text says "App ID or Services ID" matching the authorization request).

## Secrets the user must create (LM-120)

Names: `APPLE_TEAM_ID` (Membership details in developer.apple.com), `APPLE_KEY_ID`
(Keys > a key with "Sign in with Apple" enabled), `APPLE_PRIVATE_KEY` (the .p8
PEM downloaded once), `APPLE_CLIENT_ID` (the app bundle id). Put them in an
untracked env file and run `supabase secrets set --env-file <file>`; never pass
values inline or commit the file.

## Checks left for LM-120/121 (staging + real device)

- Real device: Sign in with Apple, delete account, confirm `apple_revoked:true` and the app disappears from Settings > Apple ID > Sign in with Apple.
- Confirm bundle id works as client_id (vs Services ID) and no `redirect_uri` is required.
- Confirm a fresh code from re-auth reaches the function within 5 minutes.
- Confirm missing-secret behaviour on staging yields `apple_revoked:false` and still deletes.

## Test counts (run by the controller, 2026-11-17, local)

| Ticket | Command | Result |
|---|---|---|
| LM-114/115 | the privacy-tests.yml edge-functions deno command plus `supabase/functions/delete-account/` | 94 passed, 0 failed (delete-account alone: 34 passed) |
| LM-116 | `flutter test` on `account_deletion_service_test`, `delete_account_screen_test`, `account_auth_service_test`, `dashboard_test`, `privacy_copy_test` | 56 passed, 0 failed |
| LM-116 | full `flutter test` | 1176 passed, 1 skipped, 3 failed. The 3 failures (`journal_session_lifecycle_test` x2, `off_the_record_test` x1) fail the same way on the base commit 8521923, so they are not from this work |
| LM-117 | `deletion_guard_test.sql` on a throwaway Postgres built from this branch's migrations (the shared stack on port 55322 has a different migration set and was not touched) | 73 of 73 (was 56); the whole 28-file database suite: 1105 ok, 0 not ok. Run by the Task 3 implementer, not re-run by me |

`privacy-tests.yml` runs the Deno tests (now including `delete-account`). It has no pgTAP job, so "passes in privacy-tests.yml" for LM-117 is not true yet: **decision for you** whether to add a job that runs `supabase start` and `supabase test db`.

## What was built

- `supabase/functions/delete-account/` (`handler.ts`, `apple.ts`, `index.ts`): user id only from the verified JWT (`auth.getUser`), `iat` no older than 5 minutes (the app refreshes its session right before calling), body never read except `apple_authorization_code`. Apple users: exchange the code once (retry only on transport error or 5xx), revoke the refresh token (retry once), 5 s timeout per Apple call; on failure the account is deleted anyway and the response says `apple_revoked:false`. Response `{deleted, apple_revoked}` (`null` for non-Apple users).
- App: "Delete my account" on the Privacy sheet behind `requireReauth`, a confirmation screen (what goes, cannot be undone, link to Export), the Apple sheet for Apple users, a 45 s limit on the server calls, then the existing signed-out cleanup and login with "Your account is deleted" (`lib/providers/login_notice_provider.dart`). If Apple could not be revoked the message says how to remove Lumen under Settings, Apple ID, Sign in with Apple.
- Database: `20261117000000_account_deletion_flow_state.sql` (new, beyond the ticket text). The guard test found that `auth.flow_state` (holds provider tokens) has no foreign key and survived deletion. The existing deletion trigger now also purges it, best-effort: if the function owner lacks DELETE on that table on the hosted project it warns and deletion proceeds. Applies with the normal migration deploy.

## Rulings and deviations

- JWT freshness window 5 minutes: an older stolen token must not delete an account.
- Plan was not paused for human review (the task said write the plan, then implement).
- `client_secret` lifetime is 5 minutes (limit is 6 months): it is made per request.
- Apple failure policy as in the ticket: one retry, then delete anyway.

- Ruling (final review, Important): a reply lost after the server deleted leaves the app on "Could not delete" with local data kept, and Retry then fails. Not fixed here: deciding "the user is gone" from an auth error risks wiping local data when the server did NOT delete, which is worse. Left as the follow-up below, to be designed with the real error shapes on staging.
- Minor findings left open: the Apple `id_token.sub` is not compared with the account's Apple identity (a code from another Apple ID would revoke that ID's grant; low risk on a phone); the real Dart gateway has no test pinning the field names (the fake is used; device check at LM-121); no `[functions.delete-account]` entry in `supabase/config.toml` (`verify_jwt` defaults to true).

## Doc notes for the sessions that own other docs (I did not edit them)

- `docs/security/launch-checklist.md`: add (a) the Apple secrets below are set on the hosted project, (b) after a staging deletion confirm no `auth.flow_state` row remains for the deleted user (a failed purge is only a Postgres warning), (c) decide about `auth.audit_log_entries` (actor id and email in the payload; not cascaded; not covered by any ticket).
- `docs/release-1-tickets.md`: LM-117's "passes in privacy-tests.yml" needs the CI job decision above; LM-128 must keep `notebook_commit_requests` in the guard test inventory (the table already exists on this branch from `20260821000000`, so nothing waits on LM-128 here).
- Follow-up ticket candidate: if the server deletes the account but the response is lost, the app's retry fails at `refreshSession` (user gone) and the person is stuck on a dead session. Treat that failure on a retry as "already deleted": sign out locally and show the login notice.

## Left for you

- Create the Apple secrets (section above) and the key in Apple Developer; nothing is deployed from here.
- Deploy: apply the new migration, deploy `delete-account` (with `--no-verify-jwt` NOT set, so the platform also checks the JWT), set the secrets.
- LM-120/121 checks listed above.

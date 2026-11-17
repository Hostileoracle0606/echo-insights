# Account Deletion (LM-114/115/116/117) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A signed-in person can delete their Lumen account from the app: server deletes the auth user (cascade), Apple tokens are revoked for Apple users, and the app cleans up and returns to login.

**Architecture:** A Deno edge function `delete-account` with an injectable handler (same pattern as `retrieve-memory/handler.ts`): user id comes only from a verified JWT; Apple revocation is a separate module with an injectable `fetch`; then `auth.admin.deleteUser`. The app adds a service method, a confirmation screen and a Privacy-sheet row.

**Tech Stack:** Deno edge functions + `deno test`, Supabase (pgTAP), Flutter/Riverpod, `sign_in_with_apple`.

**Spec:** tickets LM-114..117 in `docs/release-1-tickets.md` (read-only; another session owns it). Migration `supabase/migrations/20260922000000_account_deletion.sql` already purges rate limits via trigger and the other tables cascade from `auth.users`.

## Global Constraints

- Commit locally only. Never push, deploy, touch a hosted Supabase project, or put keys on a command line.
- Do not commit `pubspec.lock`, `ios/Podfile.lock`, `docs/assets`. Do not edit `docs/security/launch-checklist.md` or `docs/release-1-tickets.md`.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- User id comes ONLY from the verified JWT; the request body is never read for an id.
- No log line may contain a token, authorization code, client secret, email or error body (use `_shared/safe-log.ts`; `log-privacy.test.ts` is the marker test, keep it passing).
- Secrets the function reads (user creates them; never in repo): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (platform-provided), `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (the .p8 PEM), `APPLE_CLIENT_ID` (the app bundle id; the native code is bound to it).
- Rulings: JWT freshness window = 5 minutes (`iat`), because the app refreshes the session immediately before calling and a stolen older token must not be able to delete the account. Apple failure policy = one retry, then delete anyway and return `{deleted:true, apple_revoked:false}`.

## Review Focus

- Body `{"user_id": "<other>"}` / `{"userId": ...}` is ignored (test in Task 1).
- Expired-but-validly-signed JWT (iat older than 5 min) is refused with 401 and deletes nothing (Task 1).
- Apple secrets missing from the environment for an Apple user: treated as Apple failure (delete proceeds, `apple_revoked:false`), never a crash and never a leak (Task 2).
- Apple user who sends no `apple_authorization_code`: treated as Apple failure, delete proceeds (Task 2).
- `admin.deleteUser` error: respond 500 `{deleted:false}` and the app stays signed in with data (Tasks 1, 4).

---

### Task 1: LM-114 `delete-account` function (no Apple yet)

**Files:**
- Create: `supabase/functions/delete-account/handler.ts`, `index.ts`, `handler.test.ts`
- Modify: `.github/workflows/privacy-tests.yml` (add `supabase/functions/delete-account/` to the deno test command)

**Interfaces:**
- Produces (Task 2 extends these exact types):
```ts
export interface AdminClient {
  auth: { admin: {
    getUserById?: never;
    deleteUser(id: string): Promise<{ error: { message: string } | null }>;
  } };
  getUser(jwt: string): Promise<{ user: { id: string; identities?: {provider:string}[] } | null; error: unknown }>;
}
export interface Deps {
  admin: () => AdminClient;
  now: () => number;              // ms
  log: (fields: Record<string, unknown>) => void;
  revokeApple?: (p: { code: string | undefined }) => Promise<boolean>; // added in Task 2
}
export function createHandler(deps: Deps): (req: Request) => Promise<Response>;
```
  (Implementer may reshape `AdminClient` to the real supabase-js surface — `client.auth.getUser(jwt)` and `client.auth.admin.deleteUser(id)` — as long as `index.ts` passes a real client and tests use a fake. Keep `Deps` names.)
- Response contract: `200 {"deleted":true,"apple_revoked":boolean|null}`; `401 {"error":"unauthorized"}`; `405` non-POST; `500 {"deleted":false}`.

- [ ] Step 1: write `handler.test.ts` first, tests named: `no Authorization header -> 401, deleteUser not called`; `forged JWT (getUser returns error) -> 401, not called`; `stale JWT (iat 6 min old, validly accepted by getUser) -> 401`; `happy path deletes exactly the JWT's user and returns 200`; `body naming another user id is ignored` (deleteUser called with JWT sub only); `deleteUser error -> 500 and deleted:false`; `non-POST -> 405`; `logs contain no token`.
- [ ] Step 2: run `deno test --allow-net --allow-env --allow-read --config supabase/functions/retrieve-memory/deno.json supabase/functions/delete-account/` — expect FAIL (no handler).
- [ ] Step 3: implement `handler.ts`: read `Authorization: Bearer`, verify via `admin().auth.getUser(jwt)` (server-side signature check), read `iat` from the JWT payload (base64url decode, no trust beyond the verified token), compare to `deps.now()`. Log only non-sensitive fields via `safeLog`. `index.ts`: `serve(createHandler(...))` with the real supabase-js client built from the service role env, same import style as `retrieve-memory/index.ts`. CORS headers like the other functions if they use them.
- [ ] Step 4: tests pass; also run the full existing CI deno command from the workflow and confirm still green.
- [ ] Step 5: add the new directory to the workflow's `deno test` command; commit `feat(delete-account): edge function that deletes the caller (LM-114)`.

---

### Task 2: LM-115 Apple revocation in the function

**Files:**
- Create: `supabase/functions/delete-account/apple.ts`, `apple.test.ts`
- Modify: `supabase/functions/delete-account/handler.ts`, `handler.test.ts`, `index.ts`

**Interfaces:**
- Consumes: Task 1 `Deps`, `createHandler`.
- Produces:
```ts
export interface AppleConfig { teamId: string; keyId: string; privateKeyPem: string; clientId: string }
export function appleConfigFromEnv(env: { get(k: string): string | undefined }): AppleConfig | null;
export async function makeClientSecret(cfg: AppleConfig, nowSec: number): Promise<string>; // ES256 JWT
export async function revokeAppleAccess(p: {
  cfg: AppleConfig; code: string; fetch: typeof fetch; now: () => number; baseUrl?: string; // default https://appleid.apple.com
}): Promise<boolean>; // exchange code at /auth/token, revoke refresh_token at /auth/revoke; true on 2xx both
```
  Handler: if the verified user has an identity with provider `apple`, call revoke with the request body field `apple_authorization_code` (the only body field the handler reads), one retry on failure/throw, then delete regardless. Response `apple_revoked` is `true|false` for Apple users and `null` for others.

- [ ] Step 1: **Read Apple's current docs first** (WebFetch/WebSearch: "Revoke tokens", "Generate and validate tokens", "Creating a client secret" on developer.apple.com) and write what is confirmed, with the URLs, into `docs/superpowers/plans/2026-11-17-account-deletion-results.md` under "Apple REST API, confirmed". Must cover: token endpoint params (`client_id`, `client_secret`, `code`, `grant_type=authorization_code`), revoke params (`client_id`, `client_secret`, `token`, `token_type_hint`), content type, client-secret JWT header/claims/alg/max lifetime (6 months), which `client_id` a native iOS code uses (bundle id), whether revoking the refresh token is enough, and anything that differs from the assumptions above. Where Apple's docs cannot be fetched, say so; do not invent.
- [ ] Step 2: write `apple.test.ts` against a fake `fetch` (a Deno function recording requests): `client secret is an ES256 JWT with kid, iss=team, sub=client id, aud=https://appleid.apple.com, exp<=iat+6mo` (verify the signature with a throwaway P-256 key generated in the test); `exchanges the code then revokes the refresh token`; `token endpoint failure -> false, revoke not called`; `revoke failure -> false`; `request bodies are form-urlencoded with the confirmed params`; `config missing a secret -> appleConfigFromEnv null`. Handler tests: `apple user: revoke called before deleteUser, with the body's code`; `non-apple user: revoke never called`; `apple failure retried once then deletes anyway with apple_revoked:false`; `missing code or missing config -> delete proceeds, apple_revoked:false`; `a thrown revoke does not block deletion`.
- [ ] Step 3: confirm FAIL, implement, confirm PASS (Web Crypto `crypto.subtle.importKey("pkcs8", ...)` + `sign({name:"ECDSA",hash:"SHA-256"})`; convert nothing: Web Crypto already returns the raw r||s form JWS needs).
- [ ] Step 4: wire `index.ts` with `appleConfigFromEnv(Deno.env)` and global `fetch`. Never log the code, secret, or Apple response body. Commit `feat(delete-account): revoke Apple tokens before deleting (LM-115)`.
- [ ] Step 5: in the results file list the secrets the user must create (names above, where to get them in Apple Developer, set via `supabase secrets set --env-file` from an untracked file, never inline) and the staging/device checks left for LM-120/121.

---

### Task 3: LM-117 deletion guard covers every table

**Files:**
- Modify: `supabase/tests/database/deletion_guard_test.sql`
- Possibly create: `supabase/tests/database/account_deletion_test.sql`

**Interfaces:** none.

The existing LM-48 test already inventories `entity_suppressions`, `suppression_keys`, `forget_erase_jobs`, `notebook_commit_requests` (the table exists on this branch from `20260821000000_notebook_commit_module.sql`; do not depend on LM-128's branch — add a results-file note that LM-128 must keep it in the inventory). The gap to close: device sessions (`auth.sessions` / `auth.refresh_tokens`, rows the `list_my_sessions` RPC reads; created by Supabase Auth and cascading from `auth.users`) and any table added since the test was written.

- [ ] Step 1: diff the current `public` tables and the `auth` tables with a user FK against the inventory (query the local DB read-only; the local stack on port 55322 may belong to another worktree, so do not `db reset` it — if a fresh stack is needed use `supabase start` only if it does not clash, else report and fall back to a throwaway container).
- [ ] Step 2: extend the test: add an `auth.sessions` and `auth.refresh_tokens` seed + assertions for both users (U deleted -> zero rows, V untouched), and an assertion that every `auth` table with a `user_id` column is covered. Bump `plan(...)`.
- [ ] Step 3: write a compact `account_deletion_test.sql` only if the guard test does not already state, in plain assertions, "deleting one user leaves no row of theirs in entity_suppressions, suppression_keys, device sessions, forget_erase_jobs and leaves a second user's rows"; otherwise skip and say so.
- [ ] Step 4: run `supabase test db` (local) and record the assertion counts. Check `privacy-tests.yml`: it has no pgTAP job today; do not invent a DB CI job (needs a Supabase stack) — note in the results file that "in privacy-tests.yml" needs a decision from the user and propose the job.
- [ ] Step 5: commit `test(db): account deletion leaves no rows incl. device sessions (LM-117)`.

---

### Task 4: LM-116 "Delete my account" in the app

**Files:**
- Create: `lib/services/account_deletion_service.dart`, `lib/screens/dashboard/delete_account_screen.dart`, `test/account_deletion_service_test.dart`, `test/delete_account_screen_test.dart`
- Modify: `lib/screens/dashboard/privacy_sheet.dart`, `lib/services/account_auth_service.dart` (add `authorizationCode` to `AppleCredential` and the fetcher), the provider file that exposes `accountAuthServiceProvider` (add `accountDeletionServiceProvider`), the router/login message if needed.

**Interfaces:**
- Consumes: edge function contract from Tasks 1–2 (`POST /functions/v1/delete-account`, JSON body `{"apple_authorization_code": string?}`, bearer = a freshly refreshed access token; response `{deleted, apple_revoked}`); `requireReauth`, `signedOutCleanupProvider`, `AccountAuthService.hasAppleLinked()`.
- Produces:
```dart
enum DeleteOutcome { deleted, deletedAppleNotRevoked, cancelled }
class AccountDeletionService {
  AccountDeletionService({required AccountAuthService auth, required DeleteAccountGateway gateway});
  Future<DeleteOutcome> deleteAccount(); // Apple users: re-run Apple sheet for a fresh code (cancel => cancelled, nothing deleted)
}
abstract interface class DeleteAccountGateway {
  Future<void> refreshSession();
  Future<({bool deleted, bool? appleRevoked})> call({String? appleAuthorizationCode});
  Future<void> signOutLocal();
}
```
  Failure (non-deleted / thrown) throws `AccountAuthException('Could not delete your account. Check your connection and try again.')`; no server text surfaced.

- [ ] Step 1: tests first. Service: `non-apple user: calls gateway with no code, returns deleted`; `apple user: re-runs Apple and sends the fresh authorizationCode`; `apple sheet cancelled: nothing called, cancelled`; `server says deleted but apple not revoked -> deletedAppleNotRevoked`; `gateway failure -> throws AccountAuthException, signOutLocal not called`. Widget (use existing fakes/patterns from `test/dashboard_test.dart`, `test/app_lock_test.dart`): `Privacy sheet shows a "Delete my account" row below Export`; `failed re-auth opens nothing and deletes nothing`; `confirmation screen text names conversations, cards, map, brief and shared log, says it cannot be undone, links to Export my journal`; `cancel deletes nothing and keeps local data`; `success runs signedOutCleanup (spy), signs out, pops to login and shows "Your account is deleted"`; `Apple user success without revocation shows how to remove Lumen under Settings, Apple ID, Sign in with Apple`; `failure keeps the person signed in, keeps local data, shows retry`.
- [ ] Step 2: run `flutter test test/account_deletion_service_test.dart test/delete_account_screen_test.dart` — FAIL.
- [ ] Step 3: implement. Row key `Key('deleteAccountTile')` at the bottom of the sheet, `requireReauth(context, reason: 'Delete your account')`. Confirmation screen: destructive button `Key('confirmDeleteAccount')`, cancel `Key('cancelDeleteAccount')`. Real gateway: `Supabase.instance.client.auth.refreshSession()` then `functions.invoke('delete-account', body: {...})`. Follow `_signOutThisPhone` in `sign_in_security.dart` for cleanup/pop order. Never log or show server text.
- [ ] Step 4: tests pass; run `flutter analyze` on touched files and the existing dashboard/account tests (`flutter test test/account_auth_service_test.dart test/dashboard_test.dart test/privacy_copy_test.dart`) — all green. Do not stage `pubspec.lock`/`ios/Podfile.lock`.
- [ ] Step 5: commit `feat(app): delete my account (LM-116)`; add counts to the results file.

---

### Task 5: Results file

Collect in `docs/superpowers/plans/2026-11-17-account-deletion-results.md`: test counts per ticket (from the final runs, not from reports), Apple docs confirmed, secrets to create, doc notes (the launch-checklist and ticket doc lines other sessions should update; LM-128 note), deviations/rulings. Commit.

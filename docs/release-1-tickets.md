# Release 1: launch blocker tickets

Release 1 is the first App Store release of the iOS app, with **Forget shipped as a beta**. Phase 3 (keys only on your devices, `docs/phase3-device-keys-tickets.md`) and the open Forget questions (LM-86) are not part of it. That work continues in parallel.

Numbering continues from the Phase 3 file at **LM-113**. These tickets split the open launch blockers LM-64 to LM-68 (`docs/privacy-follow-up-tickets.md`) into pieces that can each be built or done on their own, and add the App Store items no ticket covered yet. Where a ticket replaces part of LM-64 to LM-68, it says so. The detailed steps already written in `docs/security/launch-checklist.md` are referenced, not repeated.

**Rules that still hold:** agents build and test locally only. Every deploy, console change, key rotation and push is done by the user, or by an agent after the user says yes for that step. Use `--project-ref bjoevzvsdlhlcjywpyfx` for production, and staging first every time. Copy follows what has shipped: never "keeps nothing", never "we can't read it".

## Summary

| Ticket | Title | Who | Size | Depends on |
|---|---|---|---|---|
| LM-113 | Forget a person ships as a beta | Agent | S | — (built) |
| LM-114 | `delete-account` edge function | Agent | M | — |
| LM-115 | Apple token revocation on account deletion | Agent + user (key) | M | LM-114 |
| LM-116 | "Delete my account" in the app | Agent | M | LM-114, LM-115 |
| LM-117 | Account deletion covers every table | Agent | S | LM-114 |
| LM-118 | Remove the legacy `extract-graph` (Groq) function | Agent + user | S | — |
| LM-119 | Privacy policy and App Store privacy answers | Agent drafts, user submits | M | LM-123 |
| LM-120 | Staging rehearsal of the full deploy | User (agent prepares) | M | LM-114 to LM-118 merged |
| LM-121 | Device verification pass for release 1 | User + agent | M | LM-120 |
| LM-122 | Account security and key rotation | User | M | — |
| LM-123 | Gemini billing and the paid-tier claim | User | S | — |
| LM-124 | Alerts that reach you | User | S | LM-120 |
| LM-125 | Production deploy | User | M | LM-120 to LM-124 |
| LM-126 | TestFlight and App Store submission | User + agent | M | LM-125 |
| LM-127 | Passkeys on for release 1 | Agent + user (console) | M | — |
| LM-128 | Bring LM-102/103 into release 1 | Agent | S | — |

Suggested order: LM-122 and LM-123 now, since they are console work with no code. LM-114 to LM-118 in parallel (LM-115 and LM-116 after LM-114). Then LM-119, LM-120, LM-121, LM-124, LM-125, LM-126.

## Decisions (made 2026-11-17)

1. **No penetration test for release 1.** It moves to after release 1 (LM-68's pen-test line is deferred, not dropped).
2. **LM-102/103 is in release 1** (`claude/lm-102-103-resilience-e62e25`: idempotent commits and launch catch-up). LM-128 reviews and merges it; its migration joins the deploy in LM-120.
3. **Passkeys are on for release 1** (LM-127). They depend on Supabase's passkey beta, so they get a device test of their own in LM-121.
4. **The device-list claim stays off for release 1.** Its line is already hidden (R30), so LM-66 is no longer a launch blocker.

---

### LM-113: Forget ships as a beta
**Who:** Agent · **Size:** S · **Status:** built on `feat/release-beta-forget`, not pushed

Forget keeps working exactly as merged (LM-49, LM-63, the opt-in erase), and every server part deploys in the existing order. Only what the user sees changes:
- a "BETA" tag next to "Forget <name>" on the note sheet (screen reader label "Forget <name>, beta");
- the privacy claim on the Privacy screen and `/security` now starts "Forget (beta):".

The Forget screen itself is unchanged.

**Done when:** `test/privacy_copy_test.dart` and `test/screens/journal/forget_entity_test.dart` pass (they do: 103 tests across the journal, drawer, copy and forget suites).

**Later:** dropping the tag is a one-line change in three places once LM-86 and the Phase 3 forget work settle.

### LM-114: `delete-account` edge function
**Who:** Agent · **Size:** M · **Replaces:** the server half of LM-64

Migration `20260922000000_account_deletion.sql` says the cascade runs from "auth.admin.deleteUser in the delete-account edge function", but **that function does not exist** (`supabase/functions/` has `embed-entities`, `extract-graph`, `retrieve-memory`, `speak-agent`). Nothing deletes an account today.

**Scope**
- A new edge function `supabase/functions/delete-account/`. It reads the caller's JWT, gets the user id from it (never from the request body), and calls `auth.admin.deleteUser` for that id only. The service key stays in the function's environment, never in the app.
- It refuses a request with no valid JWT, and a JWT older than a short window (the app re-authenticates just before calling it; pick the window and say why).
- It calls Apple revocation (LM-115) first when the user has an Apple identity, and only then deletes.
- Deno tests in the existing CI command: no JWT, a forged JWT, the happy path against a fake admin client, and that a body naming another user id is ignored.

**Done when:** the tests pass, and on staging (LM-120) a test account deletes itself and a second account is untouched.

### LM-115: Apple token revocation on account deletion
**Who:** Agent, plus the user for the key · **Size:** M · **Replaces:** the Apple half of LM-64

With Sign in with Apple, deleting an account must also revoke the app's Apple tokens through Apple's REST API.

**Proposed design (my call, check it against Apple's current docs before building):** no Apple token is stored. When an Apple user taps "Delete my account", the app runs Sign in with Apple once more (`getAppleIDCredential` in `lib/services/account_auth_service.dart` already does this) and sends the fresh `authorizationCode` to `delete-account`. The function exchanges the code at Apple's token endpoint for a refresh token, using a client secret it signs with the Sign in with Apple key, then calls `/auth/revoke`. The code is single-use and short-lived, so nothing lasting is kept.

**Scope**
- Revocation in `delete-account`, with a fake Apple endpoint in its tests.
- **User:** create a Sign in with Apple key in Apple Developer and store it, its key id and the team id as Supabase function secrets. Never in the repo or on the command line.
- What happens if Apple's call fails: my proposal is one retry, then delete the account anyway and tell the person how to remove Lumen under Settings, Apple ID, Sign in with Apple. A deletion should not be blocked by Apple being down. Change this if you disagree.

**Done when:** on a device, an Apple account deletes itself and Lumen no longer appears in that Apple ID's "Sign in with Apple" list.

**Unverified:** the exact token endpoint parameters and whether revoking the refresh token is enough. Read Apple's docs before building.

### LM-116: "Delete my account" in the app
**Who:** Agent · **Size:** M · **Replaces:** the app half of LM-64

**Scope**
- A "Delete my account" row at the bottom of the Privacy screen, behind `requireReauth`.
- A confirmation screen that says plainly what goes (every conversation, card, map, brief and the shared log), that it cannot be undone, and that an export is available first (link to "Export my journal").
- For Apple users, the extra Apple sheet from LM-115.
- After success: the signed-out cleanup that already exists (name map, forgotten hashes, shared log, held brief, app lock), then the login screen with a short "Your account is deleted" message.
- A failure leaves the person signed in, with their data, and a retry.
- Widget tests: cancel deletes nothing, a failed re-auth deletes nothing, success clears local data, failure keeps it.

**Done when:** the tests pass and the flow works on a device (LM-121).

### LM-117: Account deletion covers every table
**Who:** Agent · **Size:** S · **Replaces:** the test part of LM-64

**Scope**
- Extend the LM-48 guard test so any user-owned table that does not cascade from `auth.users` fails it. Include the tables added since then: `entity_suppressions`, `suppression_keys`, device sessions, `forget_erase_jobs`, and `notebook_commit_requests` from LM-102.
- A pgTAP test that deletes one user and finds no row of theirs in any of those tables, with a second user untouched.

**Done when:** both tests pass locally and in `privacy-tests.yml`.

### LM-118: Remove the legacy `extract-graph` (Groq) function
**Who:** Agent for the repo, user for the deploy · **Size:** S · **Replaces:** LM-67

It has no callers and no forget redaction, so while it is deployed it is a way around Forget.

**Scope**
- **Agent:** delete `supabase/functions/extract-graph/` and every CI step, test and doc that names it. Update `docs/security/ai-processing.md` (the Groq row and finding F1) and the launch checklist.
- **User:** look at the deployed function's invocation logs for recent calls, then `supabase functions delete extract-graph` on staging and production, and remove the Groq secret.

**Done when:** it is gone from the repo and both projects, and CI passes.

### LM-119: Privacy policy and App Store privacy answers
**Who:** Agent drafts, user reviews and submits · **Size:** M · **New**

App Store Connect needs a privacy policy URL and the App Privacy answers for every app. Neither exists: there is no privacy policy page in `src/routes`.

**Scope**
- A `/privacy` page on the web app, written from `docs/security/ai-processing.md` and `lib/privacy/privacy_claims.dart`. It must say what the app says and no more: Google processes voice and text, the companies running these services can reach data on their own systems, backups can outlive a delete for a limited time, and Forget is a beta. Add a test like `privacy_copy_test.dart` that fails if the page claims anything the `shipped` set does not.
- A draft of the App Privacy answers (data types, linked to the user, not used for tracking) as `docs/security/app-store-privacy.md`, for the user to enter by hand.
- Check whether the app needs its own `PrivacyInfo.xcprivacy`. There is none in `ios/` today, and plugins ship their own. Record the answer.

**Done when:** the user has read and approved the page and the answers. The page deploys with the web app, after the iOS release (checklist step 7).

### LM-120: Staging rehearsal of the full deploy
**Who:** User, the agent prepares · **Size:** M · **New**

Nothing from Phases 1 and 2 has been deployed anywhere. Run the whole order once on staging before production.

**Scope**
- **Agent:** one page in `docs/security/` with the exact command list for staging, built from the launch checklist section 2 with the release 1 changes: the `delete-account` function deployed, `extract-graph` deleted, and the LM-102 migration.
- **User:**
  - take a backup first, because `…200` rehashes `entity_suppressions` one way;
  - run the 18 migrations (plus any from LM-102), then the post-migration check;
  - deploy the edge functions, then `cdk deploy` with `-c alertEmail=...`;
  - point a TestFlight or simulator build at staging.

**Done when:** the post-migration check passes, a session closes without a 503, and a test account can sign up, talk, forget someone (beta) and delete itself.

### LM-121: Device verification pass for release 1
**Who:** User, with an agent fixing defects · **Size:** M · **Replaces:** LM-65 for release 1

Run the LM-65 list on a real iPhone against staging. Add: "Delete my account" for an email account and an Apple account (LM-116), and the beta tag on Forget. Passkeys (LM-127): add one, sign out, sign in with it, cancel the sheet, and one account with both an email and a passkey. Each line gets a dated pass or a filed defect. A defect in a release 1 feature blocks release; a defect in Forget can ship if its copy is changed to say so.

### LM-122: Account security and key rotation
**Who:** User · **Size:** M · **Replaces:** the LM-45 part of LM-68

Checklist section 3: MFA on Supabase, AWS and GitHub; confirm the staging CI target cannot reach production; rotate the Gemini key, then the Supabase credentials (read the legacy-key outage warning in `admin-access.md` first), the DB password and the access token; name a privacy adviser. Do this first: it has no code dependency.

### LM-123: Gemini billing and the paid-tier claim
**Who:** User · **Size:** S · **Replaces:** the LM-43 part of LM-68

The free tier allows about 20 requests a day per model, which is where the 429s come from. Release 1 cannot run on it. Checklist section 4: enable billing on the project behind `echo-insights/gemini-api-key`, retire or bill `VITE_GEMINI_API_KEY`, turn AI Studio logging off, run the 10-call burst with no 429s, ask Google the four questions in `ai-processing.md` section 4. Then an agent flips `paidTierVerified` in `lib/privacy/privacy_claims.dart` (copy test must pass).

### LM-124: Alerts that reach you
**Who:** User · **Size:** S · **Replaces:** the LM-44 and LM-54 alert parts of LM-68

Checklist section 5, without the penetration test (decision 1): confirm the SNS subscription, fire each alarm once on staging, set a Gemini budget alert, delete the old `/aws/lambda/*` log groups, enable GitHub private vulnerability reporting.

### LM-125: Production deploy
**Who:** User · **Size:** M · **New**

The LM-120 page again, on production (`bjoevzvsdlhlcjywpyfx`), only after LM-120 to LM-124 pass. Backup first. iOS ships after this, and the web app (with `/privacy` and `/security`) only after the iOS release.

### LM-126: TestFlight and App Store submission
**Who:** User, the agent prepares text · **Size:** M · **New**

**Scope**
- Bump `version`/build in `pubspec.yaml` (it is `1.0.0+1`).
- An internal TestFlight build against production first, then submission.
- **Agent drafts:** the App Review notes (what Lumen does, that it needs the microphone, the Sign in with Apple path, where account deletion is) and a demo account plan. Review needs a way in. The demo account's password is created and entered by the user, not an agent.
- **User:** screenshots, the privacy policy URL (LM-119), the App Privacy answers, and submission.

**Done when:** the build is approved, or each rejection reason has a ticket.

### LM-127: Passkeys on for release 1
**Who:** Agent for the repo, user for the console · **Size:** M · **Replaces:** the passkey line of LM-79

Passkeys are built (LM-58) but off: `lib/env.dart` enables them only with `--dart-define=PASSKEYS_ENABLED=true`.

**Scope**
- **User:** choose the relying-party domain (the web app's domain); turn on Passkeys in the Supabase dashboard for staging, then production, with that domain.
- **Agent:** serve `/.well-known/apple-app-site-association` from the web app (next to `security.txt`) with the app's team id and bundle id `com.echoinsights.lumen`. Add the Associated Domains entitlement (`webcredentials:<domain>`) to `ios/Runner/Runner.entitlements`. Make the release build define `PASSKEYS_ENABLED=true` (or flip the default, with a test). Fix the file-level ignore-comment placement for the experimental passkey API from LM-79.
- **User:** regenerate the provisioning profile with Associated Domains.
- Privacy copy: if any claim mentions passkeys, it goes in through `shipped` like the others.

**Done when:** the passkey lines in LM-121 pass on a device against staging. The web app must serve the AASA file before the iOS build ships, which reverses the usual web-after-iOS order for that one file. Deploy only the file early, not `/security`.

**Unverified:** Supabase's passkey API is a beta and may change. Re-read its docs before the console step.

### LM-128: Bring LM-102/103 into release 1
**Who:** Agent · **Size:** S · **New**

The branch `claude/lm-102-103-resilience-e62e25` (20 commits on `8817bed`, results in `docs/superpowers/plans/2026-11-16-lm-102-103-results.md`) was built by a session and has not had a final review here.

**Scope:** a final code review of the branch; fix or accept each finding; run its Flutter, Deno and pgTAP suites; merge it into the release branch with a merge commit; add its migration to the LM-120 list in file-name order.

**Done when:** the review has no open Critical or Important finding, the suites pass on the merged branch, and the deploy list includes the migration.


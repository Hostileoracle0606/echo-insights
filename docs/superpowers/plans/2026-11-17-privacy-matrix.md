# Privacy Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.


**Goal:** One command (`npm run eval:privacy`) that probes every data surface Lumen exposes with good and bad credentials against a local Supabase, and writes a pass/fail matrix with no content or secrets in it.

**Architecture:** Node ESM under `eval/privacy/`. Small pure modules (credential minting, case list, leak scan, report shaping) are unit-tested with `node --test`. Probe modules hit three surfaces: Supabase tables (PostgREST + RLS), Supabase edge functions (served locally), and the three AWS Lambdas, which are run **in-process** through their injectable `create*` factories with real local Supabase and a recording stub for the Gemini host. Leaks are detected with unique canary strings seeded into user A's data and into the fake permanent Gemini credential.

**Tech Stack:** Node 20+ ESM, `node:test`, `node:crypto` (HS256 signing; no new dependency), `@supabase/supabase-js` (already in root `package.json`), Supabase CLI local stack.

**Spec:** `docs/superpowers/specs/2026-11-17-metrics-showcase-design.md` — Track 2, "Privacy and account boundaries".

## Global Constraints

- Target is local Supabase only. Refuse to run unless `SUPABASE_URL` host is `localhost`, `127.0.0.1` or `::1`.
- Zero Gemini spend: every non-Supabase host reached through a Lambda's `fetchImpl` goes to a recording stub, never the network.
- The report contains no tokens, user IDs, emails, canary values or response bodies — only surface/target/credential/operation names, expected, observed status class, and pass.
- Every test user created by a run is deleted in a `finally`, and cleanup failure fails the run.
- Results path: `eval/results/<YYYY-MM-DD>-<shortsha>/privacy.json`.
- Positive controls are mandatory: if the owner cannot read their own canary, the run fails (a matrix that denies everyone proves nothing).

## Review Focus

1. **Vacuous security** — RLS or a function denies the owner too, so every deny cell "passes". Expected: owner-control cells must pass or the whole run fails. (Task 4, Task 7)
2. **Error bodies echo request content** — a 4xx that repeats the query back leaks it. Expected: canary planted in *request* bodies is searched for in every *response*. (Task 3, Task 5)
3. **Deleted user's still-valid token** — user C signs in, is deleted, then reuses the unexpired token. Expected: denied everywhere. (Task 2 credential kind `deleted_user`)
4. **Run aimed at the hosted project by mistake** — Expected: refuse before creating any user. (Task 7)
5. **Lambda denial after provider spend** — authorizer passes a bad token through and the handler calls Gemini before failing. Expected: the Gemini stub records zero calls on every deny cell. (Task 6)

---

### Task 1: Scaffold, local-target guard and report shape

**Files:**
- Create: `eval/privacy/report.mjs`
- Create: `eval/privacy/report.test.mjs`
- Modify: `package.json` (scripts: `"eval:privacy": "node eval/privacy/run.mjs"`, `"test:eval": "node --test eval/**/*.test.mjs"`)

**Interfaces:**
- Produces: `assertLocalTarget(url: string): URL` (throws `Error('privacy matrix runs against local Supabase only')`); `cell({surface, target, credential, operation, expected, observed}) => Cell` where `expected`/`observed` ∈ `'allow'|'deny'|'no_leak'|'leak'|'error'` and `Cell.pass: boolean`; `buildReport({commit: string, cells: Cell[], startedAt: string}) => {version: 1, target: 'local', commit, startedAt, finishedAt, summary: {total, passed, failed, controlsPassed}, cells}`; `resultsPath(date: Date, sha: string): string`.

- [ ] **Step 1: Write failing tests** — `assertLocalTarget` accepts `http://127.0.0.1:55321`, `http://localhost:55321`, `http://[::1]:55321`; throws for `https://bjoevzvsdlhlcjywpyfx.supabase.co`. `cell` sets `pass` true iff observed === expected. `buildReport` counts `controlsPassed` from cells whose `credential === 'owner'`. `JSON.stringify(buildReport(...))` contains none of the strings passed in a `forbidden` fixture list (`'CANARY-'`, `'eyJ'`, `'@example.test'`). `resultsPath(new Date('2026-11-17'), 'abc1234')` → `'eval/results/2026-11-17-abc1234/privacy.json'`.
- [ ] **Step 2: Run** `node --test eval/privacy/report.test.mjs` → FAIL (module missing).
- [ ] **Step 3: Implement** `report.mjs`. `buildReport` must refuse (throw) if any cell field contains `CANARY-` or `eyJ`, so a careless probe can't leak into the file.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): privacy report shape and local-target guard`

### Task 2: Credential kinds

**Files:**
- Create: `eval/privacy/credentials.mjs`, `eval/privacy/credentials.test.mjs`

**Interfaces:**
- Produces: `CREDENTIAL_KINDS = ['owner','missing','anon_only','expired','forged','malformed','other_user','deleted_user']`; `signJwt(payload: object, secret: string): string` (HS256 via `node:crypto` `createHmac`, base64url); `expiredTokenFor(userId: string, secret: string, now: Date): string` (claims `sub`, `role:'authenticated'`, `aud:'authenticated'`, `exp` = now − 3600s); `forgedTokenFor(userId: string, now: Date): string` (valid claims, signed with a random 32-byte secret); `MALFORMED_TOKEN = 'not-a-jwt'`; `headersFor(kind: string, tokens: Record<string,string|null>, anonKey: string): Record<string,string>` — `missing` → `{}`; `anon_only` → `{apikey: anonKey}`; others → `{apikey, authorization: 'Bearer <token>'}`.

- [ ] **Step 1: Write failing tests** — `signJwt` output has three base64url segments and its HMAC verifies with the same secret; `expiredTokenFor` payload `exp < now/1000`; `forgedTokenFor` does not verify with a known secret `'super-secret-jwt-token-with-at-least-32-characters-long'`; `headersFor('missing', …)` has no `apikey` and no `authorization`; `headersFor('anon_only', …)` has `apikey` but no `authorization`.
- [ ] **Step 2: Run** `node --test eval/privacy/credentials.test.mjs` → FAIL.
- [ ] **Step 3: Implement.** The local JWT secret comes from `SUPABASE_JWT_SECRET` (printed by `supabase status`); it is passed in, never read inside this module.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): credential kinds for privacy matrix`

### Task 3: Canaries and leak scan

**Files:**
- Create: `eval/privacy/canary.mjs`, `eval/privacy/canary.test.mjs`

**Interfaces:**
- Produces: `newCanary(label: string): string` → `'CANARY-<label>-<16 hex>'`; `findLeaks(haystacks: Array<string|object|null>, canaries: string[]): string[]` — returns the *labels* (never the values) of canaries found in any haystack (objects are `JSON.stringify`'d, header maps included).

- [ ] **Step 1: Write failing tests** — two canaries differ; `findLeaks(['x CANARY-entity-…'], [thatCanary])` → `['entity']`; nested object containing a canary in a header value is found; `findLeaks([null, ''], [c])` → `[]`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): canary seeding and leak scan`

### Task 4: Table probes (RLS)

**Files:**
- Create: `eval/privacy/probes/tables.mjs`, `eval/privacy/probes/tables.test.mjs`

**Interfaces:**
- Consumes: `cell` (Task 1), `headersFor` (Task 2), `findLeaks` (Task 3).
- Produces: `USER_TABLES` = `['profiles','notebooks','journal_entries','entities','relations','follow_ups','asked_questions','conversation_turns','conversation_runtime_sessions','conversation_runtime_inbox','notebook_commit_requests','entity_embeddings','retrieve_rate_limits']`; `expectedFor(kind: string, op: 'select'|'insert'|'update'|'delete'): 'allow'|'deny'` (owner → allow for select on every table that has an owner select policy, deny otherwise; every other kind → deny); `probeTables({url, anonKey, headersByKind, seeded: {notebookId, rowIdsByTable}, canaries, fetchImpl}): Promise<Cell[]>`.

Observation rule: `select` is `deny` when the response is 401/403 **or** 200 with zero of A's rows; `leak` when any canary appears. Writes (`insert`/`update`/`delete` targeting A's row id) are `deny` when status ≥ 400 or 0 rows affected (use `Prefer: return=representation`, `count=exact`); after the write probes, re-read A's rows with the admin client and fail the cell if anything changed.

- [ ] **Step 1: Write failing unit test** for `expectedFor` covering owner/select = allow on `entities`, `other_user`/select = deny, `expired`/delete = deny, owner/select on `retrieve_rate_limits` = deny (no client policy — verify against the migration's policies and adjust the list in the test, not the code, if the migration says otherwise).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `expectedFor` + `probeTables` using raw `fetch` to `${url}/rest/v1/<table>` (raw status codes; supabase-js masks them). **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): RLS probes across user tables`

### Task 5: Edge function probes

**Files:**
- Create: `eval/privacy/probes/functions.mjs`, `eval/privacy/probes/functions.test.mjs`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `FUNCTION_TARGETS` = `[{name:'retrieve-memory', ownerBody: true}, {name:'speak-agent', ownerBody: false}, {name:'extract-graph', ownerBody: false}, {name:'embed-entities', ownerBody: false, internal: true}]`; `probeFunctions({url, anonKey, headersByKind, notebookId, canaries, fetchImpl}): Promise<Cell[]>`.

Rules: `speak-agent` and legacy `extract-graph` are probed only with deny kinds (owner calls would spend provider quota). `embed-entities` (`verify_jwt = false`) is probed with every kind **without** `x-internal-secret` and must deny all, plus one cell with a wrong secret. `retrieve-memory` request bodies carry the `query` canary; every response body is leak-scanned. `other_user` on A's notebook expects 404 `{"error":"notebook not found"}` (as in `test_release/retrieval_release_gate_test.dart:310-311`). Owner on `retrieve-memory` is the control and must return 200 containing A's entity id.

- [ ] **Step 1: Write failing unit test** that, given a stub `fetchImpl` returning 200 + body echoing the request canary, `probeFunctions` yields a `leak` cell; given 401, yields `deny` with `pass: true`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): edge function auth probes`

### Task 6: Lambda probes, in-process

**Files:**
- Create: `eval/privacy/probes/lambdas.mjs`, `eval/privacy/probes/lambdas.test.mjs`

**Interfaces:**
- Consumes: `createSupabaseAuthorizer` (`infra/lambda/supabase-authorizer/core.mjs`), `createLiveSessionHandler` (`infra/lambda/live-session/core.mjs`), `createExtractGraphHandler` (`infra/lambda/extract-graph/core.mjs`); Tasks 1–3.
- Produces: `recordingFetch({supabaseUrl, realFetch, providerResponder}): {fetchImpl, providerCalls: () => number}` — passes through any request whose origin equals `supabaseUrl`, answers everything else with `providerResponder(request)` and counts it; `memoryClaimStore(): {acquireExtraction, completeExtraction}` with the same return shapes as `infra/lambda/extract-graph/index.mjs` (`{status:'acquired'}` / `{status:'completed', patch}` / `{status:'pending', retryAfterMs}` / `{status:'mismatch'}`); `gatewayInvoke({authorize, handler, event}): Promise<{statusCode, body, headers}>` — runs `authorize(event)`; on `isAuthorized:false` returns `{statusCode: 403}` (HTTP API simple-response behaviour); otherwise sets `event.requestContext.authorizer.lambda = context` and calls `handler`; `probeLambdas({url, anonKey, headersByKind, notebookId, canaries}): Promise<Cell[]>`.

Targets: `POST /v1/live-sessions`, `POST /v1/notebooks/{id}/live-sessions`, `POST /v1/notebooks/{id}/extractions`. `getPermanentCredential` returns the `permanent_key` canary. Provider responses: reuse the fake Gemini replies already used in `infra/test/live-session.test.mjs` and `infra/test/extract-graph.test.mjs`. Each deny cell additionally fails if `providerCalls()` advanced. Every response (body + headers) is leak-scanned for the `permanent_key` canary and A's content canaries; the owner live-session cell is the "provider secrets stay off the client" control and must return a `sessionToken` that is not the permanent key.

- [ ] **Step 1: Write failing tests** — `gatewayInvoke` with an authorizer returning `{isAuthorized:false}` yields 403 and never calls the handler; `recordingFetch` counts a request to `https://generativelanguage.googleapis.com/…` and passes through `${supabaseUrl}/auth/v1/user`; `memoryClaimStore` returns `completed` with the stored patch on a second acquire with the same input hash and `mismatch` with a different one.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(eval): in-process lambda auth probes with provider-spend check`

### Task 7: Runner, bundle scan, cleanup

**Files:**
- Create: `eval/privacy/run.mjs`, `eval/privacy/bundle-scan.mjs`, `eval/privacy/bundle-scan.test.mjs`, `eval/privacy/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `scanBundle(paths: string[], patterns = SECRET_PATTERNS): Promise<Array<{path, pattern}>>` where `SECRET_PATTERNS` = Google API key `/AIza[0-9A-Za-z_-]{35}/`, Groq `/gsk_[0-9A-Za-z]{20,}/`, a JWT whose decoded payload has `"role":"service_role"`, and the literal `EMBED_INTERNAL_SECRET` value when set; CLI `node eval/privacy/run.mjs` exiting 0 only when every cell passes, every control passes, bundle scan is clean and cleanup succeeded.

Runner order: `assertLocalTarget` → create users A, B, C via admin API (emails `privacy-matrix-<hex>@example.test`) → seed A's notebook/entity/entry/relation/turn rows with content canaries → sign in A, B, C; sign out nothing; delete C via admin (its token becomes `deleted_user`) → build `headersByKind` → run Tasks 4–6 probes → `scanBundle(['build/web', 'dist', 'build/ios/iphoneos/Runner.app'])` (skip paths that don't exist; record which were scanned) → **log audit:** leak-scan (a) the `supabase functions serve` output, which the README tells the operator to tee to the file named by `PRIVACY_FUNCTION_LOG`, and (b) everything the in-process Lambdas wrote to `console.*` during Task 6 (capture by wrapping `console.log/warn/error` for the probe's duration); any canary found adds a `surface:'logs'` leak cell; if `PRIVACY_FUNCTION_LOG` is unset, add a `logs/functions` cell with observed `'error'` so the gap is visible, not silent → `finally` delete A and B → write `buildReport` to `resultsPath` → print summary counts only.

README lists prerequisites: `supabase start`, `supabase functions serve` with local env, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`, and that the matrix does not cover hosted-only settings (hosted auth config, log retention).

- [ ] **Step 1: Write failing test** for `scanBundle` over a temp dir containing one file with a fake `AIza…` key and one clean file → exactly one finding naming the pattern, never the matched value.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `bundle-scan.mjs` and `run.mjs`. **Step 4: Run** unit tests → PASS.
- [ ] **Step 5: Run the matrix:** `supabase start`, serve functions, then `npm run eval:privacy`. Expected: exit 0, report written, summary like `cells N, passed N, controls 3/3`. If a cell fails, record it as a finding — do **not** change expectations to make it pass.
- [ ] **Step 6: Commit** `feat(eval): privacy matrix runner and bundle secret scan` (commit the first report under `eval/results/` too).

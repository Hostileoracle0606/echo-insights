# Interruptions and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Plan 4 of 6 for the metrics showcase. Test area: interruptions and recovery.

**Goal:** `npm run eval:recovery` injects failures at every durable step of a turn (after extraction, mid-commit, after commit before acknowledgement, during brief) against local Supabase and reports, per fault, whether completed turns survived, the partial turn was dropped or marked, and how many duplicate rows appeared (target: zero). Plus a scripted simulator kill test and a hand-run sheet for what can't be scripted.

**Architecture:** A fault-injecting `fetch` wraps the real one and can (a) throw before a request reaches the server, (b) let the server apply it and then throw before the response arrives ("lost acknowledgement"), or (c) kill the in-process "client" by abandoning it. After each fault a fresh client rebuilds its state only from the database and the saved turn journal, then retries the way the app does (same `requestId`, same `turnId`). The extractor is a recorded patch replayed through `createExtractGraphHandler` with a stubbed provider: recovery measures persistence, so it spends no Gemini quota (the report says so). Duplicate counts come from SQL over the test user's rows.

**Tech Stack:** Node 20 ESM, `vite-node` (for `src/lib/turn-state/*` and `src/lib/notebook-commit.ts`), `node:test`, local Supabase, `xcrun simctl` for the kill test, `integration_test`.

**Spec:** `docs/superpowers/specs/2026-11-17-metrics-showcase-design.md`, Track 2, Interruptions and recovery.

## Global Constraints

- Local Supabase only (`assertLocalTarget`). Zero provider spend (provider host answered by a stub; a counter must read 0 at the end).
- Each fault scenario runs with a fresh test user; all users deleted at the end; sweep at start (`recovery-eval-*@example.test`).
- Per fault, report: `completed_turns_kept` (n/of), `partial_turn` (`dropped` | `marked` | `duplicated` | `lost_completed`), duplicates per table (`journal_entries`, `entities`, `relations`, `conversation_turns`, `session_briefs`). Pass = all completed turns kept, partial dropped or marked, zero duplicates.
- Each fault scenario runs 10 times with different fault timings (seeded random within the step); report counts out of 10.
- Results: `eval/results/<date>-<sha>/recovery.json`, plus `recovery-manual.json` from the sheet.

## Review Focus

1. **Lost acknowledgement on commit:** the server applied the change, the client never heard; the retry with the same `requestId` must return the applied outcome, not apply again.
2. **Revision race:** two clients for the same user commit against the same `p_expected_revision`; one must get a conflict and rebase, never a duplicate entity with the same name.
3. **Turn journal replay after kill:** a turn saved to the journal but not extracted is extracted exactly once on restart.
4. **Brief written twice:** closing a session twice (retry after timeout) yields one `session_briefs` row.
5. **Fault in the fault harness:** a scenario that never actually triggered its fault is reported `not_triggered` (inconclusive), not as a pass.

---

### Task 1: Fault-injecting fetch

**Files:**
- Create: `eval/recovery/faults.mjs`, `eval/recovery/faults.test.mjs`

**Interfaces:**
- Produces: `faultyFetch({realFetch, plan: {match: (url, init) => boolean, mode: 'before'|'lost_ack', after: number}}) => {fetchImpl, triggered(): boolean}` — on the `after`-th matching request, `before` throws without calling `realFetch`; `lost_ack` awaits `realFetch` then throws `TypeError('network')`.

- [ ] **Step 1: Failing tests:** `before` never reaches the real fetch; `lost_ack` reaches it exactly once and then throws; non-matching requests pass through; `triggered()` false when the match never occurs.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): fault-injecting fetch for recovery runs`

### Task 2: Duplicate audit

**Files:**
- Create: `eval/recovery/audit.mjs`, `eval/recovery/audit.test.mjs`

**Interfaces:**
- Produces: `auditUser({url, adminHeaders, userId}) => {counts: {[table]: number}, duplicates: {[table]: number}}`; duplicate keys: entities by (notebook, lower(name)); relations by (source, target, label) where `superseded_at is null`; journal_entries and conversation_turns by (notebook, turn id); session_briefs by session id.

- [ ] **Step 1: Failing unit test** of the pure `countDuplicates(rows, keyFn)`; integration test (local only) that seeds a deliberate duplicate entity and sees `duplicates.entities === 1`.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): duplicate audit across memory tables`

### Task 3: Fault scenarios and runner

**Files:**
- Create: `eval/recovery/scenarios.ts`, `eval/recovery/run.ts`, `eval/recovery/fixtures/patches.json` (two recorded extraction patches, synthetic content)
- Modify: `package.json` (`"eval:recovery": "vite-node eval/recovery/run.ts"`)

**Interfaces:**
- Consumes: `createExtractGraphHandler`, `memoryClaimStore`, `gatewayInvoke` (privacy probes), `createTurnPipeline`/`createTurnMachine` (`src/lib/turn-state/`), `commitNotebook` request shape (`src/lib/notebook-commit.ts`), `createSessionBriefHandler` with stubbed provider, Tasks 1–2.
- Produces: `FAULTS` = `['extract_before', 'extract_lost_ack', 'commit_before', 'commit_lost_ack', 'kill_after_journal', 'kill_after_extract', 'concurrent_commit', 'brief_lost_ack']`; `runFault(name, seed) => {completed_turns_kept, partial_turn, duplicates, triggered}`.

Each scenario: 3 turns, fault on turn 2, restart a fresh client from the database and journal, finish turn 2 and turn 3, audit.

- [ ] **Step 1: Failing test** with a fake in-memory server for `commit_lost_ack`: the retry sends the same `requestId` and the audit finds one entry for turn 2.
- [ ] **Step 2–4.**
- [ ] **Step 5: Run** `npm run eval:recovery` (10 seeds × 8 faults). Record any duplicate as a finding; do not change expectations.
- [ ] **Step 6: Commit** `feat(eval): recovery fault matrix and first results`

### Task 4: Simulator kill test and manual sheet

**Files:**
- Create: `integration_test/recovery_kill_test.dart`, `eval/recovery/kill.sh`, `eval/recovery/manual-sheet.md`, `eval/recovery/record-manual.mjs`, `eval/recovery/README.md`

`kill.sh` starts a typed turn through the app on the simulator (typed turns need no mic), waits for the `[lumen-timing]` `extraction` begin mark (plan 3) or a fixed delay if that plan hasn't landed, `simctl terminate`s, relaunches, waits for `notebook_open` end, then runs the audit. Five runs each for "kill during transcription" and "kill during extraction/commit". The manual sheet covers physical-device kill, airplane mode mid-turn, and interrupting a spoken reply; `record-manual.mjs` validates sheet entries into `recovery-manual.json` (outcome enums only, no free text beyond a short note).

- [ ] **Step 1: Failing test** for `record-manual.mjs` validation (unknown outcome rejected; note longer than 140 chars rejected).
- [ ] **Step 2–4.** **Step 5:** run the kill script, fill the sheet for 3 hand runs each. **Step 6: Commit** `feat(eval): simulator kill test and manual recovery sheet`

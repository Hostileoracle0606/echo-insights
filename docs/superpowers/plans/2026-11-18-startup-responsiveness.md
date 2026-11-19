# Startup and Responsiveness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Plan 3 of 6 for the metrics showcase. Test area: startup and responsiveness.

**Goal:** Content-free timing marks in the Flutter app, a collector that turns simulator and device logs into per-stage p50/p95, and a "where the person waits" breakdown across history sizes and network profiles.

**Architecture:** A small `TimingMarks` recorder in `lib/logic/` emits one JSON line per mark, prefixed `[lumen-timing]`, only when the app is built with `--dart-define=LUMEN_TIMING=1` (off in shipped builds; works in profile mode, unlike `vlog`, which is debug-only). Marks sit beside the existing `vlog('timing', …)` calls. A shell collector launches the app repeatedly on the simulator with `xcrun simctl launch --console-pty`, captures the lines, and a pure Node summarizer computes percentiles. Retrieval latency is measured separately from Node against local `retrieve-memory` (free). Voice stages need real speech, so they come from hand-run device sessions on a recording sheet, collected through the same log format.

**Tech Stack:** Dart/Flutter, `xcrun simctl`, Node 20 (`node:test`), Network Link Conditioner (manual), local Supabase.

**Spec:** `docs/superpowers/specs/2026-11-17-metrics-showcase-design.md`, Track 2, Responsiveness.

## Global Constraints

- Marks carry stage names, millisecond offsets, counts and booleans only: never transcript text, entity names, ids or tokens. A unit test enforces the field allow-list.
- Timing is off unless `LUMEN_TIMING=1` is defined at build time; no change in behaviour or output for normal builds.
- Report p50 and p95 per stage with N, device, build mode (profile) and network profile. Never mix simulator and device numbers in one figure.
- Seeded history sizes: empty, ~50 and ~500 entities, created on local Supabase only.
- Voice runs spend Gemini Live quota (20/day): budget ≤10 voice sessions per day, shared with any other Live use.

## Review Focus

1. **Profile vs debug:** debug builds are several times slower; the collector refuses logs whose header says `mode=debug`.
2. **Background-init overlap:** if opening-prep or snapshot reload runs during an active turn, the mark records `overlap=true`; the summary reports how often.
3. **Missing end marks:** a stage with a start and no end (crash, cancel) is counted as `incomplete`, never dropped silently.
4. **Clock source:** all offsets come from one monotonic `Stopwatch` started in `main()`; wall-clock time never enters a duration.
5. **Cold vs warm start:** the collector terminates the app and waits before each cold launch; warm launches are labelled separately.

---

### Task 1: TimingMarks recorder

**Files:**
- Create: `lib/logic/timing_marks.dart`, `test/logic/timing_marks_test.dart`
- Modify: `lib/main.dart` (start the clock first thing; mark `process_start`, `first_frame` via `addPostFrameCallback` after `runApp`)

**Interfaces:**
- Produces: `class TimingMarks { static final instance; void start(); void mark(String stage, {Map<String, Object> fields = const {}}); void begin(String stage); void end(String stage, {Map<String, Object> fields}); }`; `const allowedFieldKeys = {'count','bytes','overlap','scope','size','ok','retry'}`; output line: `[lumen-timing] {"v":1,"stage":"…","t_ms":123,"dur_ms":45,"mode":"profile",…}`; a `sink` parameter for tests.

- [ ] **Step 1: Failing tests:** disabled by default emits nothing; enabled emits one line per mark with `t_ms` from the monotonic clock; `end` without `begin` emits `incomplete`; a field key outside `allowedFieldKeys` throws in debug and is dropped in profile; a string field value is rejected (numbers and booleans only).
- [ ] **Step 2:** `flutter test test/logic/timing_marks_test.dart` → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(timing): content-free timing marks behind LUMEN_TIMING`

### Task 2: Marks at every waiting point

**Files:**
- Modify: `lib/providers/journal_provider.dart` (next to existing `vlog('timing', …)` at the open, retrieve, extract, commit points; mic open; first assistant audio in `onAudio`; user turn end), the home screen widget that first shows notebooks (mark `home_interactive`), `lib/providers/opening_prep_provider.dart` (`opening_prep` begin/end and `overlap` when a turn is active)
- Test: `test/journal_timing_marks_test.dart`

Stages (exact names): `process_start`, `first_frame`, `home_interactive`, `notebook_open` (begin/end, `size` = entity count bucket), `tap_to_mic_open`, `user_turn_end_to_first_audio`, `retrieval` (`scope`, `count`), `extraction`, `commit` (`retry`), `opening_prep` (`overlap`).

- [ ] **Step 1: Failing widget/provider test** with a fake sink: opening a seeded notebook emits `notebook_open` begin and end; a simulated assistant audio chunk after a user turn end emits `user_turn_end_to_first_audio` once per turn, not per chunk.
- [ ] **Step 2–4.** Then run `flutter test` (whole suite) and `flutter analyze` → clean.
- [ ] **Step 5: Commit** `feat(timing): mark startup, open, voice and memory stages`

### Task 3: History seeding and simulator collector

**Files:**
- Create: `eval/timing/seed.mjs`, `eval/timing/collect.sh`, `eval/timing/parse.mjs`, `eval/timing/parse.test.mjs`

**Interfaces:**
- Produces: `node eval/timing/seed.mjs --entities 0|50|500` → creates a local test user with that many synthetic entities/relations, prints only the email (password from env `TIMING_USER_PASSWORD`); `collect.sh <device> <runs> <label>` → builds profile with `LUMEN_TIMING=1` once, then for each run: `simctl terminate`, sleep 2 s, `simctl launch --console-pty`, capture 20 s of `[lumen-timing]` lines into `eval/results/<date>-<sha>/timing/<label>-<n>.jsonl`; `parseRun(text) => Mark[]` (ignores non-timing lines, rejects `mode=debug`).

- [ ] **Step 1: Failing tests** for `parseRun`: mixed log text yields only timing marks; a debug-mode header throws; a malformed JSON line is counted in `rejected`, not thrown.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): timing seed and simulator collector`

### Task 4: Retrieval latency from Node

**Files:**
- Create: `eval/timing/retrieval.mjs`

Runs `retrieve-memory` 50 times per history size against the local stack with the seeded user's token (warm-up 5 discarded), writes `retrieval-<size>.jsonl` in the same mark format (`stage:"retrieval_server"`). No Gemini spend.

- [ ] **Step 1:** reuse `parseRun` tests (format identical). **Step 2:** implement and run. **Step 3: Commit** `feat(eval): server-side retrieval latency runs`

### Task 5: Summarizer, device sheet and first results

**Files:**
- Create: `eval/timing/summarize.mjs`, `eval/timing/summarize.test.mjs`, `eval/timing/device-sheet.md`, `eval/timing/README.md`
- Modify: `package.json` (`"eval:timing:summary": "node eval/timing/summarize.mjs"`)

**Interfaces:**
- Produces: `percentile(values: number[], p: number): number` (nearest-rank); `summarize(marks: Mark[], meta) => {stages: {[stage]: {n, p50, p95, incomplete}}, overlapRate: [overlaps, of], meta}` → `timing.json`.

- [ ] **Step 1: Failing tests:** nearest-rank p50/p95 on known arrays (`[1..20]` → p50 10, p95 19); incomplete stages counted; simulator and device inputs with different `meta.device` refuse to merge.
- [ ] **Step 2–4.**
- [ ] **Step 5: Collect:** simulator cold start ×20 per history size; retrieval ×50 per size; device sheet: 5 voice sessions on Wi-Fi, 3 on "LTE", 2 on "3G" (Network Link Conditioner), each exported via the same log lines. Record misses honestly.
- [ ] **Step 6: Commit** `feat(eval): timing summary and first results`

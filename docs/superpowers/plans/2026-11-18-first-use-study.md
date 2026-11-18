# First-Use Study Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Plan 5 of 6 for the metrics showcase. Test area: first-use experience.

**Goal:** A ready-to-run study kit (protocol, consent, observation sheet, seeded account) and a small recorder and summarizer, so 3–5 people new to Lumen can be observed and the results counted without keeping any of their content.

**Architecture:** Mostly documents. Code is limited to: a seed script for a fresh study account, a CLI that validates one session's observations into JSON, and a pure summarizer. Participants use a TestFlight or simulator build on a seeded local or staging account (the owner picks; never their own account).

**Tech Stack:** Markdown, Node 20 (`node:test`), local Supabase (or a staging project the owner names).

**Spec:** `docs/superpowers/specs/2026-11-17-metrics-showcase-design.md`, Track 3.

## Global Constraints

- 3–5 participants who have not used Lumen. Participants are coded P1…P5; no names, emails or recordings stored in the repo.
- Consent covers: what is observed, that nothing they say is kept, that quotes appear only if they approve the exact wording, and that they can stop at any time.
- Tasks, in order: (1) talk through your day; (2) find what Lumen kept; (3) correct one thing it got wrong.
- Recorded per participant: time to first successful turn (seconds), task completion (yes/with help/no) per task, confusions (coded from a fixed list plus "other"), three comprehension checks scored correct/partial/wrong: what is it for; is it listening now; what will it keep.
- The study account is wiped after each participant (`seed.mjs --reset`).

## Review Focus

1. **Leading questions:** the facilitator script must not explain listening state or memory before the comprehension checks.
2. **Content leakage:** the recorder rejects free-text fields longer than 140 characters and any field named like transcript/content.
3. **Unapproved quotes:** a quote without `approved: true` is dropped from the summary.
4. **Small N:** the summary reports counts ("2 of 4"), never percentages.
5. **Leftover account data:** reset is verified by counting the account's rows after the wipe.

---

### Task 1: Study kit documents

**Files:**
- Create: `eval/first-use/protocol.md` (facilitator script with exact wording, timings, when to help), `eval/first-use/consent.md`, `eval/first-use/observation-sheet.md` (printable, same fields as the JSON), `eval/first-use/confusion-codes.md` (fixed list: mic_state, what_to_say, where_memory_is, correction_path, permissions, other)

- [ ] **Step 1:** write the four documents; check each recorded field in the sheet maps to one field in Task 2's schema.
- [ ] **Step 2: Commit** `docs(eval): first-use study protocol, consent and sheet`

### Task 2: Seed, recorder and summarizer

**Files:**
- Create: `eval/first-use/seed.mjs`, `eval/first-use/record.mjs`, `eval/first-use/record.test.mjs`, `eval/first-use/summarize.mjs`, `eval/first-use/summarize.test.mjs`, `eval/first-use/README.md`

**Interfaces:**
- Produces: `seed.mjs [--reset]` (study account with an empty notebook; `--reset` deletes the account's rows and prints remaining row counts, which must be 0); `validateSession(obj) => Session` (throws on unknown fields, codes or enums; on any string > 140 chars; on participant ids not matching `^P[1-9]$`); `record.mjs <sheet.json>` writes `eval/results/<date>-<sha>/first-use/P<n>.json`; `summarize(sessions) => first-use.json` with medians and ranges of time to first turn, completion counts per task, confusion counts per code, comprehension counts per question, approved quotes only.

- [ ] **Step 1: Failing tests:** each validation rule above; `summarize` on 4 hand-built sessions gives the expected counts and drops an unapproved quote.
- [ ] **Step 2–4.** **Step 5: Commit** `feat(eval): first-use recorder and summarizer`

### Task 3: Pilot and sessions (owner-run)

- [ ] **Step 1:** one pilot run with someone friendly; adjust protocol wording only (record changes in the README).
- [ ] **Step 2:** run 3–5 sessions, record each, reset between them.
- [ ] **Step 3:** `node eval/first-use/summarize.mjs` and commit `first-use.json`.

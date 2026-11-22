# Externalize conversation context

**Status** — proposed tickets; EC-01 implemented as a flagged spike.
**Branch** — `feat/externalized-context`.

The live session window should never be Lumen's memory. Structured records in
the graph are the single source of truth, and each Gemini Live session gets a
small, deduplicated context rebuilt from them. Direct questions are answered by
deterministic fact tools. The transcript is kept as the store of record (for
re-extraction, corrections and Forget) and is never searched to answer.

## Why change it

- **Compaction.** Long sessions rely on Gemini's sliding-window compression
  (`context_window_compression` in [`gemini_live_client.dart`](../lib/services/gemini_live_client.dart)).
  Gemini decides what to summarise or drop, invisibly, and can lose a fact that
  mattered. A bounded, rebuilt context never needs compressing.
- **Duplication.** A transcript repeats facts and keeps old and new versions
  side by side ("my goal is 200" … "I raised it to 350"). The model has to work
  out which is current. One record per entity and attribute removes the
  conflict.
- **Accuracy.** The model reads typed records, not prose. On the memory-routing
  eval (`codex/memory-query-routing-tickets`), two of four live misses came from
  interpreting raw passages at query time ("from $200 to $350", an itemised
  list). Write-time structure removes that step from the spoken turn.
- **Latency.** Query-time passage extraction costs ~1–1.5 s per memory question.
  A typed fact lookup costs milliseconds. Extraction already runs at write time
  ([`extract_graph_service.dart`](../lib/services/extract_graph_service.dart)),
  so this moves work off the spoken turn rather than adding a model.

Gemini Live reads `client_content` only before the first reply
(`sendHistory` in the client). New context therefore reaches a running session
only through a tool response or a new connection. Rebuilding is a
connection-level operation, and how often it happens decides how natural Lumen
feels.

## Ticket order

| Ticket | Deliverable | Area | Size | Depends on |
|---|---|---|---|---|
| [EC-01](#ec-01--spike-bounded-session-rebuild-at-a-pause) | Flagged rebuild-at-a-pause spike with timing | Flutter | S | — |
| [EC-02](#ec-02--fact-layer-schema) | Fact records with versions, status and provenance | Supabase | M | — |
| [EC-03](#ec-03--write-time-upsert-extraction) | Extraction that confirms, supersedes or corrects | Extraction | L | EC-02 |
| [EC-04](#ec-04--session-state-record) | Open threads, mood, commitments, covered | Flutter / Supabase | M | EC-02 |
| [EC-05](#ec-05--context-materialiser) | Working set + session state + recent turns, on a budget | Flutter | M | EC-01, EC-02, EC-04 |
| [EC-06](#ec-06--fact-tools) | Deterministic fact tools for direct questions | Server / Flutter | M | EC-02, EC-03 |
| [EC-07](#ec-07--correction-flow) | Dispute, read back, confirm, apply | Flutter / server | M | EC-02, EC-06 |
| [EC-08](#ec-08--forget-export-and-deletion-coverage) | Privacy coverage for every new record | Privacy | M | EC-02, EC-04, EC-07 |
| [EC-09](#ec-09--backfill-existing-journals) | Facts for journals written before EC-03 | Extraction | M | EC-03 |
| [EC-10](#ec-10--latency-and-naturalness-gate) | Timing, boundary checks, blind listening test | Eval / release | M | EC-01; EC-05–EC-07 for rollout |
| [EC-11](#ec-11--pre-warmed-switch-only-if-ec-01-gap-is-audible) | Pre-warmed second connection | Flutter / infra | M | EC-01 result |

EC-01 is the gate: if a rebuild at a pause can't be made inaudible, use the
single-session fallback (bounded start context, fact tools, rebuild only on
Forget or session limits) and keep EC-02–EC-09.

## EC-01 — Spike: bounded session rebuild at a pause

**Scope.** Behind `CONTEXT_REBUILD_ENABLED` (a `--dart-define`, off by
default), turn off Gemini's sliding-window compression and instead rebuild the
session from saved context once a turn budget is spent. Reuse the existing
fresh-reconnect path (`_reopenWithSavedContext`, used for Forget and returning
to the record): drop resumption, hold mic input, take a new token, reconnect,
seed recent turns and the graph summary, release input.

Rebuild only when nobody has the floor: Lumen's audio has drained, the user is
not speaking, no reply is awaited, no reconnect is running, the session is live
and on the record. Off the record never rebuilds, because rebuilt context comes
only from saved turns. A maximum session age guarantees a rebuild before
Gemini's ~15-minute audio limit, since compression is off.

Log, without content: rebuild reason, turns and age at rebuild, time to setup,
time to context seeded, and the first reply latency after a rebuild.

**Code anchors** — [rebuild policy](../lib/logic/context_rebuild_policy.dart),
[journal provider](../lib/providers/journal_provider.dart),
[Live client setup](../lib/services/gemini_live_client.dart),
[resume context](../lib/logic/resume_context.dart).

**Done when**

- [x] A pure policy decides when to rebuild, with unit tests for the budget,
  age, minimum interval and every "someone has the floor" condition.
- [x] With the flag on, setup omits `context_window_compression`; with it off,
  setup is unchanged.
- [x] The provider rebuilds at a pause through the existing fresh-reconnect
  path and logs timing without content.
- [x] Typed turns with the mic paused also rebuild (found in the Simulator:
  the composer pauses the mic, and the first version only rebuilt when live).
- [x] Simulator, typed turns, `CONTEXT_REBUILD_MAX_TURNS=3` (2026-11-21, one
  run): rebuild started 0.8 s after Lumen's third turn and was seeded in
  395 ms (socket 159 ms, setup 218 ms, held credential). First reply after
  the rebuild: 742 ms plain (before: 933 and 1,008 ms), 1,700 ms with a
  memory tool call (before: 1,684 ms). Lumen kept the thread and gave the
  savings goal stated before the rebuild; no re-greeting.
- [ ] Spoken turns on a device, with a listening check at the rebuild point
  (EC-10). One Simulator run is not a latency distribution.

## EC-02 — Fact layer schema

**Scope.** Add a fact table attached to existing entities:
`entity_id`, normalised `attribute`, `value_num` / `value_text` / `unit`,
`status` (`confirmed`, `proposed`, `cancelled`), `event_at` and `stated_at`,
`supersedes_fact_id`, `retracted_at` with a reason (`corrected`, `user_removed`),
`provenance` (`extracted`, `user_corrected`) and `source_entry_id`. Owner-only
RLS and `security definer` writes, as for relations.

A real-world change supersedes (the old value stays as history). A correction
retracts (the wrong value never appears as history). Keep both distinct.

**Done when**

- [x] Migration, RLS tests and contract schema in `contracts/`.
- [x] "Current", "previous", "as of" and "history" are single indexed queries.
- [x] Retracted facts are excluded from every read path, including history.

**Built** (`feat/ec-02-fact-layer`). `memory_facts` with owner-only reads that
never show retracted rows, and writes only through `insert_memory_fact` and
`retract_memory_fact`. Reads: `get_memory_fact(entity, attribute, scope, at)`
for `current`, `previous` and `as_of` (confirmed values only), and
`get_memory_fact_history` (every live version, plans included). Versions are
ordered by `event_at`, else `stated_at`, on `memory_facts_version_idx`.
Contract: `contracts/memory-fact-v1.schema.json`, checked by
`_shared/memory-fact-contract.ts` and by the database test.
`scripts/staging-db-test.py` runs pgTAP files on staging in one transaction
that always rolls back (there is no local Docker database).

## EC-03 — Write-time upsert extraction

**Scope.** Extend write-time extraction to emit facts and upsert them: a new
statement about an existing entity and attribute confirms it (no change),
supersedes it, or is ignored as a repetition. Normalise attributes against
existing keys (embedding match on attribute names, with a merge path for
later collisions). Resolve relative dates ("last Tuesday") at write time
from `spoken_at`. A change sentence ("from X to Y") records Y, with X
confirming the prior version. Never overwrite a `user_corrected` fact.

**Done when**

- [x] Repeating a fact creates no duplicate row.
- [x] A changed value supersedes with correct `event_at` ordering, stable
  under out-of-order entries.
- [x] "Savings goal" and "monthly savings target" land on one attribute in the
  labelled fixtures.
- [x] Editing an entry re-derives its facts, except pinned corrections
  (`record_memory_facts(..., p_replace => true)`; the app has no entry
  editing yet, so nothing calls it).

**Built** (`feat/ec-03-fact-extraction`).

- **Database** (`record_memory_facts`): every decision is made in SQL, so a
  retried or restored turn adds nothing. Outcomes: `repeat`, `superseded`,
  `history` (said now about an earlier time), `pinned` (a correction made
  after the statement wins) and `inserted`. "From X to Y" records Y and
  confirms X when X is not already the version in effect.
  `list_memory_fact_keys` returns the attribute names in use.
- **Extraction** (`infra/lambda/extract-graph`): the model also returns
  `facts`. It is shown the fact keys already stored for the turn's entities
  (read with the user's own token, best effort) and `SAID AT`, the user's own
  date, so "last Tuesday" resolves on their calendar. Each fact is checked on
  its own; a malformed fact never costs the turn its entities. A placeholder
  previous value ("unknown", or the new value again) is dropped.
- **App**: `GraphPatch.facts` (kept in the durable checkpoint), `spokenAt`
  on the extraction request, and the facts recorded against the server's
  entry id once the commit succeeds. Best effort: a failure leaves the turn
  saved without facts (EC-09 can derive them). Off the record nothing is
  extracted, so nothing is recorded. The noise filter drops the facts of an
  entity it drops.

**Changed from the plan.**

- Attribute names are matched by the model against the keys already stored,
  not by embeddings. The model sees the turn in context; an embedding of two
  words does not. The merge path for later collisions is still open.
- A value that is itself an entity stays a relation ("Priya is moving to
  Lisbon" is `Priya --moving_to--> Lisbon`). The model did this every time,
  whatever the prompt said, and the graph already answers it. Facts hold
  values that are not entities: amounts, counts, dates, percentages, text.

**Real-model check** (`scripts/fact-eval.py`, staging, Gemini 2.5 Flash):
14 of 15 case runs pass over three runs. The goal and "monthly savings
target" land on one key, "from 1500 to 1700" gives current 1700 and previous
1500, "last Tuesday" resolves to 17 Nov, an unsure "maybe 2k?" is never
confirmed. The one miss: a turn's plan ("raise it to 10k next year") was
left out once.

## EC-04 — Session state record

**Scope.** A short-lived record per conversation, updated at write time:
open threads (unanswered questions, paused topics), current emotional
register, commitments ("I'll remind you…") and what Lumen has already said or
asked. Included in every rebuilt context. Folded into the next session brief
or deleted when the conversation ends.

**Done when**

- [ ] A rebuilt session continues an open question instead of re-asking it.
- [ ] Content already covered is not repeated after a rebuild.
- [ ] Forget and off-the-record rules apply to the record.

## EC-05 — Context materialiser

**Scope.** Build the rebuilt context from external state only: persona and a
continuation line, the opening brief, the working set (one row per active
entity and attribute, current value, history only when relevant), session
state, and the last few turns verbatim (redacted for Forget). Enforce a
token budget; rank the working set by relevance to active entities, one-hop
neighbours and recency. Replace `graphSummary` and the 20-turn replay in
rebuilds.

**Done when**

- [ ] The context is bounded and contains no duplicate fact.
- [ ] The same graph and session state always produce the same context.
- [ ] Rebuild triggers move from turn count to the token budget, plus Forget
  and confirmed corrections.

## EC-06 — Fact tools

**Scope.** Live function tools that read typed facts with no model call:
`memory_fact(entity, attribute, scope)`, `memory_event_status(event)`,
`memory_total(category, period?)` and `memory_change(entity, attribute)` with
deterministic arithmetic, and `memory_recall(topic)` as the free-form fallback.
Tool results say "latest stored as of <time>" so a newer statement in the
conversation takes priority. Instruct Lumen to call a tool, never guess, for
anything outside its context. Reuse the plan/completion and version rules from
the memory-routing branch, moved onto typed facts.

**Replaces the query-time resolver.** Routed recall (`retrieve-memory` v3)
still extracts facts from linked entries with a Gemini 2.5 Flash call on every
question ([`evidence.ts`](../supabase/functions/retrieve-memory/evidence.ts)).
That call does no arithmetic, which is already code. It turns sentences into
numbers, units, dates and plan-or-done, and it costs ~1.5 s per question. It
also labels the same entries differently from run to run: on staging (22 Nov
2026), "What did I say about Priya?" and "What did the user say about Priya?"
returned different clarifications over the same three entries. With EC-02 and
EC-03 storing those facts once, at write time, the router chooses which tool
to call and the answer needs no model. The resolver is then deleted.

Open recall (router: `recall` with an `unspecified` time scope) no longer
calls the resolver. It returns the graph's top linked entries as quotes
(`feat/open-recall`). Only calculations, version questions and event
confirmation still pay for the query-time call until this ticket lands.

**Done when**

- [ ] The MQ eval cases pass against the tools with no passage extraction.
- [ ] Tool latency p95 is under 300 ms server side.
- [ ] Routed calculate, version and confirm-event questions make no model call
  after the router, and `evidence.ts` is removed.

## EC-07 — Correction flow

**Scope.** Tools for a user objection: `memory_dispute(fact_id)`,
`memory_propose_correction(fact_id, change)` returning a pending correction and
a read-back sentence built by code, and `memory_apply_correction(pending_id)`.
Nothing is written until the user confirms. Ask one targeted question only when
the objection is underspecified, or which fact when the last answer used
several. After two rejected read-backs, offer to remove the fact or mark it
disputed. Corrections retract (EC-02) and pin. Correction turns are flagged so
extraction does not record them again.

**Done when**

- [ ] Value, date, status, attribution and removal corrections each round-trip.
- [ ] After a corrected value, "previous" never returns the wrong value.
- [ ] Re-extraction after an entry edit keeps the correction.

## EC-08 — Forget, export and deletion coverage

**Scope.** Facts, session state, pending and applied corrections are derived
journal content. Forget, Forget-person, auto-forget, export and account
deletion (LM-48, LM-49, LM-51, LM-52, LM-63) must cover them. A Forget during a
conversation ends the current session at once and rebuilds from the graph after
the deletion, with redacted replay.

**Done when**

- [ ] Each privacy path has a test that covers every new table.
- [ ] After a mid-session Forget, the rebuilt context contains no trace of it.

## EC-09 — Backfill existing journals

**Scope.** Run EC-03 extraction over existing entries, oldest first, resumable
and rate-limited, honouring Forget state at run time.

**Done when**

- [ ] A backfilled journal answers EC-06 queries equal to one extracted live.
- [ ] Interruption and resume produce no duplicates.

## EC-10 — Latency and naturalness gate

**Scope.** Measure and gate rollout:

- p50 / p95 time from end of user speech to first audio, for normal turns,
  tool turns and the first turn after a rebuild. The rebuild turn must fall
  within the normal-turn distribution.
- Automated boundary checks on rebuild turns: re-greeting, repetition of
  covered content, the last open thread addressed.
- A blind listening test: reviewers mark where they hear a reset. Gate:
  rebuild points detected no more often than chance.
- Deep-history cases (old version behind 40+ recent entries) and the EC-07
  correction scenarios.

**Done when**

- [ ] Reports exist for Simulator and device runs.
- [ ] A documented go / no-go for the rebuild design, or the single-session
  fallback.

## EC-11 — Pre-warmed switch (only if EC-01 gap is audible)

**Scope.** Open the next connection with its own credential (tokens are
single-use) while the current one is talking, seed it, keep its input held,
and move audio at the pause. Cancel if the user starts speaking. Confirm
concurrent-session limits and how long a seeded connection stays ready.

**Done when**

- [ ] The rebuild turn's latency matches a normal turn on device.

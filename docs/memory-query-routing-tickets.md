# Route memory questions through tools

**Status** — proposed implementation tickets. **Branch** — `codex/memory-query-routing-tickets`.

When a user asks about their journal, Gemini Live passes the full question to one
memory tool. The server uses Gemini Decisions to identify the requested operation
and time scope, then runs the lookups and checks needed to answer. Gemini Live
receives a supported result, a clarification, or an insufficient-evidence result
to say aloud.

## Why change it

Lumen’s current [tool definition](../lib/providers/journal_provider.dart) asks the
model for a few search words. The [account-wide retrieval handler](../supabase/functions/retrieve-memory/handler.ts)
finds quotes through graph entities and returns empty when the graph is empty.
In the shortened 300-history local eval, keyword plus vector passage search
represented all labeled sources in 257 of 276 answerable cases. Fusing in graph
quotes recovered zero additional complete cases. See the report at
`c20791c:eval/local-memory/PASSAGE-COMPARISON.md` on `codex/memory-retrieval-experiment`.

Gemini Live replayed frozen passages correctly on 11 of 14 clearly answerable
questions and safely declined or clarified all seven unsupported questions. It
gave the current goal when asked for the previous one, left two calculations
unfinished, and speculated that a proposed coffee-limit change had happened.
Those replays instructed Gemini to call the tool and supplied its response.
A separate six-question Decisions smoke test selected the expected operation
and time scope in all six cases in a retry run. Successful requests took about
half a second, and an earlier request timed out. These are selected local
experiments. The new end-to-end eval measures how often the production path
finds the evidence, routes correctly, and answers within a voice turn.

## Ticket order

| Ticket | Deliverable | Area | Size | Depends on |
|---|---|---|---|---|
| [MQ-01](#mq-01--carry-the-full-question-through-the-memory-tool) | Full question and a versioned memory tool contract | Flutter / server | M | — |
| [MQ-02](#mq-02--route-requests-with-gemini-decisions) | Decisions routing with a bounded fallback | Server / Gemini | M | MQ-01 contract |
| [MQ-03](#mq-03--search-eligible-journal-passages-directly) | Direct passage retrieval with optional graph expansion | Supabase / retrieval | M | MQ-01 contract |
| [MQ-04](#mq-04--resolve-current-previous-and-confirmed-facts) | Time-scoped facts and event confirmation | Memory / graph | M | MQ-02, MQ-03 |
| [MQ-05](#mq-05--calculate-from-supported-values) | Calculation from source-backed values | Server / memory | S | MQ-02, MQ-03; MQ-04 for changes over time |
| [MQ-06](#mq-06--check-evidence-and-speak-the-result) | Evidence verdict and spoken-answer integration | Server / Flutter | M | MQ-01, MQ-03, MQ-04, MQ-05 |
| [MQ-07](#mq-07--measure-routing-retrieval-and-spoken-accuracy) | Held-out voice eval and staged rollout | Eval / release | M | MQ-01 contract for fixtures; MQ-02–MQ-06 for rollout |

MQ-02 and MQ-03 can proceed in parallel once the contract is agreed. MQ-07 can
prepare and validate cases while the implementation is in progress.

## MQ-01 — Carry the full question through the memory tool

**Scope.** Extend `get_relevant_memory` with the complete question. Keep the
short query available as a search hint and support existing callers through
the versioned contract. Use the question from the current tool call or the
same user turn when available. Pass phrases such as “before I updated it,”
“actually,” and “in total” through to the server. Request only the minimum
session context needed to resolve a reference such as “that goal.”

Define the server-owned, read-only workflow and its result types. A supported
result carries the selected fact or calculation and source references. A
clarification carries the distinction the user needs to resolve. An
insufficient-evidence result carries a safe response. Keep internal source
IDs available for validation and eval while the spoken response uses natural
language. Track one shared deadline across routing and tool execution, using
the existing 3.5-second account-wide retrieval timeout as the first test budget.

**Code anchors** — [Flutter tool call](../lib/providers/journal_provider.dart),
[request and response](../lib/services/retrieve_memory_service.dart),
[server handler](../supabase/functions/retrieve-memory/handler.ts).

**Done when**

- [ ] One Live tool call sends the full current question and preserves its
  original time or calculation wording across the Flutter and server boundary.
- [ ] A short-query caller continues to receive its existing response. The
  versioned workflow can be tested with fixture results for all three outcomes.
- [ ] Deadline expiry produces an explicit fallback outcome within the voice
  budget, and a late result is discarded for that turn.

## MQ-02 — Route requests with Gemini Decisions

**Scope.** Use `gemini-decision-1` server-side. Score operation and time scope as
separate closed-set choices in one call. Start with recall, confirm an event,
calculate, and ordinary conversation. Time scope covers current, previous,
a specified date or period, comparison across versions, and unspecified. The
server validates the choices and selects the allowed tool sequence. A request
to calculate how much a goal increased combines an earlier-and-later lookup
with calculation.

Set confidence thresholds against labeled fixtures. On a weak or conflicting
decision, use direct passage lookup with the full question when it can safely
help, or ask a targeted clarification. Use the same bounded fallback for a
provider timeout or unavailable credential. Store the provider credential on
the server through the existing credential mechanism. Route with the question
and the minimum permitted context. Record route, elapsed time, confidence
range, and fallback reason without logging question or journal text.

**References** — [Gemini Decisions API](https://aistudio.google.com/docs/decisions-api),
[server-side Gemini credential pattern](../infra/lambda/live-session/index.mjs).

**Done when**

- [ ] Paired previous, current, and difference questions over the same goal
  produce distinct tool plans. A plan-versus-confirmation question chooses the
  confirmation route, and an ordinary conversational turn skips memory lookup.
- [ ] Stubbed timeout, invalid choice, and low-confidence results follow the
  documented fallback within the shared deadline.
- [ ] A live smoke test records route accuracy and latency. Its output contains
  neither a credential nor private journal text.

## MQ-03 — Search eligible journal passages directly

**Scope.** Add account-scoped keyword and vector search over eligible journal
passages. Return source IDs, relevant excerpts, and dates. Keep the original
passage as evidence. Graph entities and relations can suggest additional
sources for identity or cross-entry questions. Choose between vector-only and
keyword/vector fusion on paired evidence coverage under the same context budget.

Apply the existing journal eligibility and outbound text rules before indexing
and reading passages. Use the eligible context projection. Respect Forget,
off-record, edits, deletion, account scope, and device-only context. Remove or
invalidate stale search records and check source eligibility again before
returning a hit. Use aggregate counts to track which search path supplied
evidence.

**Code anchors** — [account-wide retrieval](../supabase/functions/retrieve-memory/handler.ts),
[graph traversal](../src/lib/graphloop/retrieve.ts),
[Forget and context projection](../supabase/migrations/20261112100000_forget_everywhere.sql).

**Done when**

- [ ] An eligible journal entry answers a recall question when its graph is
  empty or extraction missed the relevant fact. A graph expansion can surface
  a linked eligible entry and preserve its source reference.
- [ ] Edited, forgotten, deleted, off-record, cross-account, and device-only
  fixtures enforce their existing visibility rules, including during reindexing.
- [ ] Passage-only and passage-plus-graph runs report complete evidence
  coverage and latency under the same budget.

## MQ-04 — Resolve current, previous, and confirmed facts

**Scope.** Resolve versions against dated, source-backed entries. Reuse the
existing supersession information where it is linked to evidence. Prefer
the date of the event when the passage states it. Use the journal entry date
to date the statement otherwise. A current lookup selects the latest confirmed
value. A previous or date-scoped lookup can select an older eligible entry.
Track explicit plans separately from confirmed changes. If the available
history does not establish which version applies, return uncertainty or ask
about the missing distinction.

**Code anchors** — [existing relation lifecycle](../src/lib/graphloop/graph-ops.ts),
[graph merge and supersession](../src/lib/journal-store.ts).

**Done when**

- [ ] A goal that changed from 100 to 150 returns 100 for “previous,” 150 for
  “current,” and both with their sources for “how much did it change?” The
  result is stable when the same passages arrive in a different order.
- [ ] A confirmed cut to one cup followed by a proposal to go back to two is
  returned as a confirmed cut and a proposal. Adding an explicit confirmation
  supports a current limit of two.
- [ ] Conflicting records, uncertain event dates, and similar names produce
  qualified results when the timeline cannot be resolved from eligible sources.

## MQ-05 — Calculate from supported values

**Scope.** Add a server calculation step for explicit totals, differences, and
counts. Accept typed operands with source references, units, and any relevant
dates or categories. Validate that they describe the requested set, deduplicate
repeated references to one fact, and calculate in code. Return the number and
its scope to the responder. For an open-ended question about the whole journal,
qualify a subtotal or abstain when the available records do not establish
completeness.

**Done when**

- [ ] Four documented categories with counts 12, 57, 25, and 5 produce 99, and
  confirmed goals of 100 and 150 produce an increase of 50.
- [ ] “Over $300 in Hawaii and around $30 in Tokyo” remains approximate in
  the spoken result. Mixing currencies, missing operands, or repeated mentions
  never produces a fabricated or double-counted exact total.
- [ ] A request for headphones plus an iPad can return the known headphone
  price and ask for the iPad price. A phone case price does not fill that slot.

## MQ-06 — Check evidence and speak the result

**Scope.** Require the result to be supported by eligible passages for the
requested person, role, event, date, and any calculation operands. Check
selected source IDs against the candidates and the current access scope.
Use deterministic validation for known IDs, dates, units, and arithmetic.
Use a bounded evidence check when support depends on what a passage means.
Handle insufficient evidence and unresolved identities explicitly. Where
the deadline allows, try one narrower lookup before declining or clarifying.

Pass the approved fact, calculation, or uncertainty to Gemini Live. Instruct
it to answer the recall question directly before any conversational follow-up.
Test whether it preserves the approved result in audio. If it still invents a
material claim, record the example for a separate playback decision.

**Code anchors** — [tool result assembly](../lib/services/retrieve_memory_service.dart),
[conversation policy](../lib/logic/conversation_policy.dart).

**Done when**

- [ ] A candle bought for Mom cannot support an answer about what Dad gave
  the user. An explicit gift from Dad is returned with the supporting entry.
- [ ] If evidence is ambiguous, too weak, or has become ineligible during the
  request, the spoken turn asks for clarification or says what is unknown.
- [ ] The recorded answer includes the requested older value or calculated
  total when the tool already returned it, with any uncertainty preserved.

## MQ-07 — Measure routing, retrieval, and spoken accuracy

**Scope.** Prepare a small held-out set with source passages checked by a human.
Include ordinary conversation, supported and unsupported recall, historical
versions, plans versus completed actions, calculations, and eligibility cases.
Start with fixed passages to compare the answer workflow to the current one.
Then exercise the real tool and retriever with normal Gemini Live instructions.
Score the chosen route and time scope, usable evidence, the spoken answer,
correct abstention, and clarification separately. Report end-to-end p50 and
p95 latency, provider timeouts, and fallback counts.

**Done when**

- [ ] The held-out set includes matched current, previous, and difference
  questions, plus a plan-with-confirmation-removed/restored pair. Each
  answerable case has checked evidence for its answer key.
- [ ] The report can attribute a miss to routing, retrieval, evidence handling,
  or the spoken result. A timeout on an answerable case counts as a miss.
- [ ] Before enabling broadly, the paired report shows whether the routed path
  improves grounded answers while preserving abstention and the voice latency
  budget. Start behind a flag and document how to turn it off if results regress.

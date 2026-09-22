# Finalized-turn extraction state model

Status: implemented. Supersedes the abort-only, cumulative-prefix extraction
flow described as the "current behaviour" in
[`streaming-extraction-correctness-research.md`](./streaming-extraction-correctness-research.md).

Date: 2026-09-10

## What changed, in one paragraph

Extraction used to run on every sentence boundary, carrying the cumulative
turn-so-far, and each run could complete a durable database write. Cancelling
the previous request was the only protection against duplicates — and
cancellation cannot undo a write that already committed. Now interim transcript
text is explicitly replaceable display state, only an immutable **finalized**
transcript may change the canonical graph, every asynchronous result is checked
against a five-part identity before it is allowed to matter, and each finalized
transcript carries one stable commit request identifier through extraction,
commit, retry and crash recovery.

## Where authority lives

| Concern | Owner |
| --- | --- |
| What a turn is; which transitions are legal | `src/lib/turn-state/reducer.ts`, `lib/logic/turn_state.dart` |
| Protocol signals → turn events | `src/lib/turn-state/transcript-assembler.ts`, `lib/logic/transcript_assembler.dart` |
| Performing effects (model, network, storage) | `src/lib/turn-state/pipeline.ts`, `JournalNotifier._performEffect` |
| Concrete web I/O | `src/lib/turn-state/web-adapter.ts` |
| Prompt context selection and budget | `src/lib/extraction-context.ts` |
| Atomic write, idempotency, revision check | `public.commit_notebook` (unchanged) |

The reducer is platform-free: no React, no Flutter, no network, no database.
The web and Flutter ports implement the *same rules*; only the adapters differ.

## The state model

Every turn carries a stable `turnId`, a monotonically increasing
`transcriptVersion`, a `sessionId` and `notebookId`, a `generation`, and — once
durable processing begins — a stable `commitRequestId`.

```
                 interim transcript (replaceable, version N → N+1)
                          │
  listening ──────────────┤ optional: provisional extraction  ── display only
                          │                                      never durable
                          ▼
                   turn completed ──────► awaitingFinal
                          │                    │
        final transcript  │                    │ final transcript, or deadline
                          ▼                    ▼
                    ┌─────────── finalized transcript (immutable) ──────────┐
                    │                                                        │
                    │  finalRecorded → extracted → commitPending → committed │
                    └────────────────────────────────────────────────────────┘

  assistant playback ──► interrupted ──► only the heard prefix may finalize
                                          (unknown boundary → nothing at all)
```

### Transitions and what triggers them

| Event | Effect |
| --- | --- |
| `sessionStarted` (same notebook) | Clears active/awaiting turns and the preview. **Keeps** pending durable turns — a reconnect must not strand an unconfirmed write. |
| `sessionStarted` (different notebook) | Full reset. |
| `interimTranscript` | Replaces the active turn's text, `transcriptVersion += 1`. Emits provisional extraction only if enabled. |
| `finalTranscript` | Records authoritative text. If the turn is already complete, finalizes it now. |
| `turnCompleted` | If authoritative text is present, finalizes. Otherwise parks the turn in `awaiting` and schedules a deadline. |
| `finalizationDeadline` | Finalizes with whatever text exists — unless the turn already finalized, in which case it does nothing (no phantom turn). |
| `playbackAdvanced` | Moves the assistant heard-character watermark. |
| `assistantInterrupted` | Truncates assistant text to the heard prefix at a word boundary and locks it. `heardChars: null` marks the turn undeliverable. |
| `provisionalExtractionSettled` | Identity-checked. On success sets the preview **and nothing else**. |
| `durableExtractionSucceeded` | Identity-checked. Stores the result, checkpoints it, then starts the commit. |
| `commitCommitted` | Drops the turn from the queue and the journal; advances the known revision. |
| `commitConflict` | Records the server revision and asks for a snapshot reload. Holds the queue. |
| `snapshotReloaded` | Rebases the head turn's `baseRevision` and replays pending turns in order. |
| `commitUnknown` | Retries the identical commit with the same request id. |
| `restored` | Loads journal checkpoints into the queue and resumes each from its own stage. |

Invalid or stale transitions are rejected deterministically: the state is
unchanged and `staleRejections` increments.

## Identity checks, not cancellation

An `AbortSignal` still reaches the extraction request and its retry waits, but
cancellation is now explicitly **a resource optimisation**. Before any awaited
result may change state, all of the following must still match:

- session identifier
- notebook identifier
- turn identifier
- transcript version
- extraction generation

A result failing any check changes nothing — not the graph, not the activity
display, not the thinking indicator, not the database.

One subtlety worth stating: a durable extraction's key carries the turn's *own*
session id, not whichever socket happens to be open when it returns. A finalized
turn's work is notebook-scoped; a reconnect must not invalidate it.

## One finalized transcript, one durable turn

The cumulative-prefix problem is fixed at the adapter seam. Chunks accumulate
into a *replaceable* interim transcript; nothing durable happens until a turn is
explicitly completed. So:

```
"I work at Acme."                          → interim, version 1
"I work at Acme. My manager is Sarah."     → interim, version 2
final + turn complete                      → ONE finalized turn
```

Gemini's `turnComplete` describes the model's turn, so the user turn is closed
by the first assistant output that follows user speech, with `turnComplete` as
the fallback for a turn the assistant never answered.

Final transcription and turn completion may arrive in either order: whichever
arrives second finalizes the turn. If neither the authoritative transcript nor
the deadline has fired, the turn waits in `awaiting`, held separately from
`active` so the *next* turn's first interim chunk cannot displace it.

## Crash recovery and idempotency

Stages are checkpointed to a turn journal (`localStorage` on web) **before** the
step they authorise:

- **after recording the final transcript, before extraction** — restart
  re-extracts from the stored immutable transcript;
- **after extraction, before commit** — restart reuses the stored extraction
  result instead of paying for the model again (and instead of risking a
  *different* result);
- **after sending the commit, before the response arrives** — restart retries
  the identical request with the same `commitRequestId`.

That last case is safe because of how `public.commit_notebook` already works:

1. It records an idempotency row **only for committed outcomes**. A conflict or
   rejection returns before the insert.
2. An exact retry (same request id, same `{change, expectedRevision}` hash)
   replays the stored result without re-applying anything.
3. The same request id with different input is rejected as `requestIdReused`.

Two consequences the client design leans on:

- Reusing one request id across a **conflict rebase** is safe — a conflict left
  no ledger row, so the rebased attempt proceeds normally.
- If the commit had silently succeeded and the client rebases anyway, the
  differing hash returns `requestIdReused` rather than double-applying. The
  ledger is a guard, not just a cache.

`supabase/tests/database/notebook_commit_test.sql` sections 9 and 10 pin both
down.

Multiple pending turns are processed strictly in the order they were spoken,
one durable step in flight at a time. On a conflict the authoritative snapshot
is reloaded and every pending turn replays in order, keeping its original
request identifier. Serialising also improves extraction quality: turn two is
extracted against a graph that already contains turn one.

## Interrupted assistant speech

The transcript reveal loop already lip-syncs agent text to the audio playback
clock. That reveal *is* the heard watermark, so it is a measurement rather than
an estimate. On barge-in:

- playback is flushed and later generation for that turn is dropped;
- the transcript is truncated to the watermark, backing off to the last complete
  word — a half-spoken word was not heard as that word;
- the truncated text becomes the finalized turn, and the canonical conversation
  history records only that;
- if no audio clock was available, the boundary is reported as **unknown** and
  the turn is skipped for durable extraction entirely.

A transcript gate then drops any output transcription that arrives after the
interruption, so a late "finished" transcription cannot re-attach the unheard
tail.

## Economical extraction context

Web `compileExtractionContext` and Flutter `compileExtractionContext` replace
the old count-sliced context builders, which
constructed graph statistics, gaps, focus entities, bridging candidates,
previously-asked questions and recent entries that the prompt never read, and
bounded what it *did* read by item counts.

For each finalized transcript:

1. the transcript is the semantic retrieval query;
2. retrieval (`retrieveMemory` → GraphLoop `retrieve`) returns semantically and
   lexically relevant entities;
3. exact normalized-name matches are always ranked first — they are the identity
   anchors that stop the model minting a duplicate node;
4. relevant active relations among the kept entities are expanded in;
5. entity and **relation identifiers are preserved**, so `supersedes` can point
   at the right edge when the user contradicts something;
6. the open question being answered is added;
7. as many recent finalized turns as still fit are added;
8. everything is packed under **one explicit token budget**, measured against
   the rendered prompt rather than against item counts.

Counts survive only as safety limits (`MAX_PROMPT_ENTITIES` and friends). The
budget is the real bound, and `estimateTokens` is injectable so a real
tokenizer can replace the estimator without touching the packing logic.

The new utterance is the only source of new facts. Retrieved records and prior
turns are grounding material for identity resolution, pronouns, deduplication
and contradiction handling; the prompt says so explicitly and the new-utterance
section contains only the current transcript.

## Known limitations

- **The token estimator is an estimator.** `estimateTokens` approximates a
  SentencePiece vocabulary at roughly one token per four characters of word
  body. It is deterministic and injectable, but it is not the provider's
  tokenizer, so the budget is approximate in the same direction for every turn.
- **The web turn journal is `localStorage`.** It survives reload and crash, but
  not a cleared profile, a different browser, or private-mode storage denial.
  Recovery degrades to "the turn is lost"; live behaviour is unaffected.
- **Flutter semantic retrieval is fail-closed.** If the authenticated retrieval
  edge function is unavailable, extraction still includes literal exact-name
  matches but omits semantic candidates for that turn; live capture continues.
- **A failed durable extraction drops its turn.** `extractGraph` already retries
  429s internally, but a hard failure removes the turn from the queue rather
  than scheduling a later retry.
- **Provisional extraction is off by default.** The reducer and pipeline support
  it and it is proven display-only by test, but no adapter enables it.

## Potential future addition: bounded extraction recovery

The current short retry window protects against brief transient failures, but a
mobile-network handoff, longer provider outage, expired session, or malformed
response can still permanently remove a finalized turn from semantic memory.
This normally does not stop the live conversation, so the user may discover the
loss only later when Lumen fails to recall something they already said.

The repository does not yet collect the production metric needed to state the
real failure probability. If the probability that one extraction remains
failed after inline retries is `q`, the probability of at least one lost job in
`n` jobs is `1 - (1 - q)^n`. For example, a 0.5% post-retry failure rate becomes
about a 9.5% chance of at least one loss over 20 jobs and 18.2% over 40 jobs.
Retries during the same outage are correlated, so treating the three attempts
as independent would understate this risk.

A future recovery path should:

- preserve finalized user turns in the durable journal after retryable failure;
- retry later with exponential backoff, jitter, a maximum attempt count and
  explicit terminal-failure state;
- bound the queue by count and age while retaining the original transcript and
  request identity;
- keep extraction and commits ordered within one notebook, while allowing the
  backend to process different notebooks concurrently;
- expose pending count, oldest-job age and terminal failure to both telemetry
  and a small user-facing “memory syncing” status; and
- measure extraction result, latency, retry count and dropped-turn count before
  setting a production reliability target.

This is a reliability improvement, not part of the currently implemented
finalized-turn state model.

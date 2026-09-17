# Streaming extraction correctness and context management research

Status: research and design guidance only. No application code was changed.

**Superseded in part.** The recommendations here were implemented on
2026-09-10; see [`finalized-turn-extraction.md`](./finalized-turn-extraction.md)
for what was actually built. The "Current Echo Insights behavior" section below
describes the code *before* that change and is kept as the rationale record.

Date: 2026-09-07

## Question

How do comparable conversational and durable-execution systems handle partial
transcripts, cancellation, late results, replay, and bounded model context, and
which mechanisms should Echo Insights adopt around `src/routes/index.tsx`?

## Executive conclusion

Echo Insights should not treat cancellation as its correctness guarantee.
Cancellation is a resource-saving request; a **generation guard** must decide
whether a result is still allowed to change state.

The safest target design is:

1. Treat interim transcript text as replaceable display state.
2. Give every spoken turn a stable turn identifier and a monotonically
   increasing transcript version.
3. Run provisional extraction for responsiveness, but do not durably commit it.
4. On an authoritative final transcript, cancel the provisional request, advance
   the generation, extract exactly once from the immutable final turn, and
   commit with an idempotency key derived from the turn and final version.
5. Persist stage outcomes so retries resume after the last completed boundary
   instead of repeating model calls or database effects.
6. Build each extraction prompt from a token-budgeted, deterministic context:
   the current final turn, a compact session summary, recent final turns, and
   retrieved graph facts with provenance. The graph remains the source of truth;
   summaries and sliding windows are disposable model context.

This preserves the current live visual feedback while preventing an older or
cumulative extraction from being committed twice.

## Current Echo Insights behavior

### What is already sound

- `extractAbortRef` cancels the previous extraction request when a newer
  cumulative transcript arrives
  (`src/routes/index.tsx`, lines 488-490 and 659-686).
- The same cancellation signal reaches both the network request and retry delay
  (`src/lib/extract-graph.ts`, lines 693-711 and 763-787).
- The `finally` block clears the thinking indicator only for the controller that
  is still current (`src/routes/index.tsx`, lines 714-720). This is already a
  controller-identity guard for user-interface state.
- Database commits are serialized within one browser tab, and the notebook
  revision protects cross-session writes (`src/routes/index.tsx`, lines
  462-477 and 563-650).
- Agent interruption flushes unheard audio and clears the pending agent
  transcript (`src/hooks/use-gemini-live.ts`, lines 421-426).

### Correctness gaps

1. **Cancellation is trusted after the await.** After `extractGraph` resolves,
   the code does not check that its controller or generation is still current
   before merging and queuing a commit (`src/routes/index.tsx`, lines 678-705).
   A provider, proxy, or intermediate operation that completes despite
   cancellation can therefore publish a stale result. React's official
   data-fetching example uses an independent ignore guard specifically because
   responses may arrive out of order; the same principle applies here.
   [React `useEffect` reference](https://react.dev/reference/react/useEffect#fetching-data-with-effects)

2. **Cumulative text can create cumulative durable effects.** Sentence one may
   finish extraction and commit. The next callback submits sentence one plus
   sentence two and can commit the earlier content again. Cancelling only the
   currently running request cannot undo an earlier successful commit. The
   comment that a newer call “supersedes” the older one is true for in-flight
   computation, but not for completed durable writes
   (`src/routes/index.tsx`, lines 656-705; `src/hooks/use-gemini-live.ts`, lines
   343-370 and 396-413).

3. **Transcript semantics are implicit.** The client labels
   `inputTranscription` as “partial or final” and appends every received value
   (`src/lib/gemini-live-client.ts`, lines 76-78 and 341-346;
   `src/hooks/use-gemini-live.ts`, lines 343-345). The current Gemini Live
   protocol distinguishes frequently updated interim transcription from final
   input transcription, and says input transcription is delivered independently
   with no guaranteed ordering. Append-only treatment is therefore not a safe
   general interpretation of the provider contract.
   [Gemini Live WebSocket reference](https://ai.google.dev/api/live#bidigeneratecontentservercontent)

4. **A finalization signal is overloaded.** `onTurnComplete` finalizes both user
   and agent buffers. Gemini documents that interruption follows the sequence
   `interrupted` then `turnComplete`, while input transcription has no ordering
   guarantee relative to other messages. A robust adapter should expose typed
   events such as `interimUserTranscriptReplaced`, `finalUserTranscript`,
   `agentInterrupted`, and `agentTurnCompleted`, rather than make the route infer
   meaning from one shared buffer boundary.
   [Gemini Live WebSocket reference](https://ai.google.dev/api/live#bidigeneratecontentservercontent)

5. **Unknown commit outcomes cannot be replayed.** A request identifier is
   created inside each attempt. If transport fails after the server commits,
   the identifier is lost and the function returns (`src/routes/index.tsx`,
   lines 575-592). The existing Notebook Runtime contract correctly says to
   retain and reuse the same request identifier when the outcome is unknown
   (`docs/notebook-runtime-interface.md`, retry rule 2).

6. **Context is count-bounded, not token-budgeted.** The route constructs a
   broad context object containing entities, relations, entries, conversation,
   graph gaps, follow-ups, focus entities, prior questions, and bridging
   candidates (`src/routes/index.tsx`, lines 249-323 and 670-683). The current
   prompt formatter uses only the first 20 entities, 30 relations, and four
   conversation turns (`src/lib/extract-graph.ts`, lines 474-490), so much of
   that constructed object is currently unused. Even the smaller prompt is
   bounded by item counts rather than tokens or relevance: a few long fields
   can consume the budget, while an older but relevant fact can be omitted.

## Comparable systems and transferable mechanisms

### Google Gemini Live: explicit event meanings and provider context compression

The current Gemini Live reference separates:

- `interimInputTranscription`: low-latency text that is frequently updated;
- `inputTranscription`: input audio transcription delivered independently, with
  no guaranteed ordering;
- `interrupted`: a signal to stop and empty playback;
- `generationComplete`: generation finished; and
- `turnComplete`: the model's turn is complete. An interrupted response does
  not emit `generationComplete`; it proceeds through `interrupted` to
  `turnComplete`.

[Gemini Live WebSocket reference](https://ai.google.dev/api/live#bidigeneratecontentservercontent)

Google's guidance also says to immediately discard client audio when an
interruption arrives and to enable context-window compression for long audio
sessions. Its documented sliding-window example evicts old tokens after a
trigger is reached.
[Gemini Live best practices](https://ai.google.dev/gemini-api/docs/live-api/best-practices)

**Transfer to Echo Insights:** expose these distinctions in
`gemini-live-client.ts` instead of reducing them to untyped chunks. Replace the
display value when interim text changes; finalize extraction only from final
text. Enable provider context compression for the live dialogue, but do not
mistake the provider's sliding window for durable memory.

### OpenAI Realtime: synchronize heard audio with conversation history

OpenAI Realtime emits incremental and completed input-transcription events with
item identifiers. When a user interrupts assistant audio, the client can cancel
the response and truncate the assistant item at the amount actually played.
The server then removes unheard transcript text from its context, keeping the
model's conversation aligned with what the user actually heard.

[OpenAI Realtime server events](https://platform.openai.com/docs/api-reference/realtime-server-events/input_audio_buffer/committed)

OpenAI Realtime also supports retention-ratio truncation: when the context is
too large, it drops enough old content to retain a configured fraction rather
than repeatedly removing tiny prefixes. This reduces repeated truncation and
improves prompt-cache reuse.
[OpenAI Realtime reference](https://platform.openai.com/docs/api-reference/realtime)

**Transfer to Echo Insights:** keep a playback watermark for agent speech and
never extract durable facts from agent words that were generated but not heard.
The current interruption path already clears buffered agent text before its
turn-complete extraction, which is directionally correct. Make the watermark
and interruption generation explicit so ordering is testable.

### React and Redux Toolkit: cancellation plus a latest-generation gate

React's official example prevents a late network result from updating state by
setting an independent `ignore` flag during cleanup. Redux Toolkit assigns each
asynchronous request a unique request identifier, exposes a cancellation signal,
and includes the identifier in completion actions so state logic can accept only
the current request.

- [React race-condition guard](https://react.dev/reference/react/useEffect#fetching-data-with-effects)
- [Redux Toolkit asynchronous request identifiers and cancellation](https://redux-toolkit.js.org/api/createAsyncThunk)

**Transfer to Echo Insights:** increment `extractionGenerationRef` for every
replacement, capture the value in the request, and check it immediately after
every awaited boundary and immediately before merge or commit. Abort the old
network request as an optimization; generation equality is the correctness
rule.

### LangGraph: checkpoints for short-term execution state, stores for durable facts

LangGraph persists a thread snapshot at graph-step boundaries. Its documentation
separates checkpointers, which hold thread-scoped execution state for resume and
fault tolerance, from stores, which hold durable application facts across runs.
Replay skips nodes before a chosen checkpoint and re-executes later nodes.

- [LangGraph persistence](https://docs.langchain.com/oss/javascript/langgraph/persistence)
- [LangGraph time travel and replay](https://docs.langchain.com/oss/python/langgraph/use-time-travel)

**Transfer to Echo Insights:** separate ephemeral turn-processing state from the
canonical notebook graph. A checkpoint can say “final transcript stored,
extraction output stored, database commit pending”; the graph store contains
only committed notebook facts. Resume from the checkpoint rather than guessing
from the current interface state.

### Temporal: durable event history and cooperative cancellation

Temporal records workflow events so execution state can be recreated after a
failure. Its official TypeScript samples demonstrate cancellable network calls,
activity heartbeats, and cancellation propagation. The important transferable
idea is not adopting Temporal itself: external effects must occur at named,
recorded boundaries, and cancellation must propagate into the work while
durable history determines what already happened.

- [Temporal event-history walkthrough](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/event-history/java.mdx)
- [Temporal TypeScript cancellation and heartbeat samples](https://github.com/temporalio/samples-typescript/tree/main/activities-cancellation-heartbeating)

**Transfer to Echo Insights:** record the result of expensive extraction before
attempting the notebook commit. A retry can reuse the recorded extraction
instead of paying for and potentially receiving a different model result.

### OpenAI Agents software development kit: persist completed turns, serialize compaction

The OpenAI Agents TypeScript documentation persists streaming user input first
and appends streamed output after the turn completes. Its compaction session
serializes history mutations, replaces a long history with compacted items, and
recommends manual compaction between turns or during idle time when streaming
latency matters. It also warns that mixing client-managed and server-managed
history can duplicate context.

- [OpenAI Agents sessions and compaction](https://openai.github.io/openai-agents-js/guides/sessions/)
- [OpenAI Agents context management](https://openai.github.io/openai-agents-js/guides/context/)

**Transfer to Echo Insights:** compact only at a final-turn boundary and
serialize compaction with history updates. Maintain one owner for conversational
history. Keep canonical graph facts outside the lossy compacted summary.

## Recommended target state machine

```text
No active turn
  -> speech starts
Collecting turn
  -> interim transcript replacement
Collecting turn, version N
  -> optional provisional extraction starts for version N
  -> newer interim text arrives
Collecting turn, version N+1
  -> cancel version N and reject any late version-N result
  -> final transcript arrives
Final turn recorded
  -> cancel provisional work and advance generation
  -> final extraction starts from immutable transcript
Final extraction recorded
  -> notebook commit starts with stable request identifier
  -> committed
Turn complete at notebook revision R

At any stage:
  -> process restarts
  -> load last durable stage and continue from there

On database revision conflict:
  -> load authoritative notebook snapshot
  -> reapply pending finalized-turn events in order
  -> retry recomputed change with a new request identifier

On unknown database outcome:
  -> retry the identical commit with the same request identifier
```

## Concrete data roles

| Value | Role |
|---|---|
| `sessionId` | Separates reconnections and prevents an old socket from publishing into a new session. |
| `turnId` | Stable identity for one logical user or agent turn. |
| `transcriptVersion` | Increases whenever replaceable transcript text changes. |
| `extractionGeneration` | Determines whether an asynchronous result is still publishable. |
| `transcriptStatus` | `interim` or `final`; only `final` authorizes a durable notebook change. |
| `transcriptHash` | Proves which exact immutable text produced an extraction. |
| `extractorVersion` | Makes changes to prompts, schemas, or model choice explicit during replay. |
| `baseRevision` | Notebook revision against which the pure merge was computed. |
| `requestId` | Stable identity for one database mutation; reused when its outcome is unknown. |
| `processingStage` | Durable checkpoint such as `finalRecorded`, `extracted`, or `committed`. |

## Recommended context compiler

Use one deterministic context-building function with a token budget and this
priority order:

1. Current immutable final transcript.
2. Explicit answer-target information, if the turn answers a follow-up.
3. Exact graph facts retrieved by mentioned names and aliases.
4. Semantically related active relations, each with its durable identifier.
5. Open follow-ups and recently asked questions relevant to those entities.
6. A compact session summary containing unresolved references and decisions.
7. As many recent finalized turns as fit in the remaining budget.

Do not include the same entity catalogue both as a top-level field and inside
the context. Do not ask the model to reconstruct durable facts from a lossy
summary. A summary is useful for discourse continuity; the graph and notebook
entries remain authoritative.

Provider context compression and this extraction context solve different
problems:

- Gemini context-window compression bounds the persistent live conversation.
- The Echo Insights context compiler bounds each separate extraction request.
- Retrieval restores older relevant facts that either sliding window omitted.

## Suggested implementation sequence

1. **Add generation guards without changing product behavior.** Keep current
   cancellation, add session and extraction generations, and reject late
   results after every awaited boundary.
2. **Correct the adapter contract.** Represent interim replacement, final input,
   interruption, generation completion, and turn completion as distinct events.
3. **Stop committing cumulative prefixes.** Either commit only once from the
   final transcript, or make provisional results interface-only and reconcile
   them with one final commit.
4. **Make the final turn durable.** Move final transcript, extraction result,
   processing stage, and stable request identifier behind the Notebook Runtime.
5. **Rebase pending turns on conflict.** Preserve an ordered list of finalized
   local turn events and replay them over the fresh server snapshot instead of
   replacing local state with one retried turn.
6. **Introduce the context compiler.** Measure actual tokens, retrieve facts by
   relevance, remove duplicate representations, and compact only the
   conversational portion between turns.
7. **Enable Gemini live-session compression and resumption.** Store the newest
   resumable session handle and respond to advance-disconnect messages, while
   retaining the notebook as the independent durable source of truth.

## Required tests before rollout

- An old extraction resolves after a newer one even though cancellation was
  requested; only the newer generation may merge or commit.
- Sentence one completes before sentence two arrives; finalization creates one
  journal turn and does not double its entity mentions.
- Interim text is revised rather than extended; the final extraction uses only
  the authoritative replacement.
- Final input transcription arrives before and after the model turn-complete
  event; no phantom turn or dropped turn occurs.
- Agent audio is interrupted after partial playback; unheard agent words never
  enter extraction context or the graph.
- The process stops after extraction but before commit; restart reuses the
  stored extraction output.
- The server commits but the response is lost; retry uses the same request
  identifier and produces no duplicate effect.
- A cross-device revision conflict occurs with two local finalized turns queued;
  both are replayed in order over the fresh snapshot.
- A large graph and long conversation stay within the configured prompt budget,
  while a relevant older fact is retrieved with its durable identifier.

## Decision boundary

Adopting LangGraph or Temporal is not necessary for this change. Their useful
ideas can be implemented in the planned Notebook Runtime with a small durable
turn-processing table and explicit state transitions. A workflow engine becomes
worth evaluating only if Echo Insights later needs many long-running,
multi-service stages, human approval pauses, or operational replay across
several workers.

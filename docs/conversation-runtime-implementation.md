# Shared conversation runtime implementation

Status: implementation in progress; deployment is a separate release operation.

## Contract and ownership

The TypeScript turn reducer and transcript assembler run on AWS. Web and Flutter
send observations; only the worker produces extraction/commit outcomes. Audio,
immediate interruption, and provisional display remain local. Supabase remains
the notebook authority. A session has one writing device and one authenticated
owner; notebook revisions reconcile simultaneous sessions.

All routes use the existing authenticated Notebook Runtime base URL:

- POST `/v1/notebooks/:notebookId/conversations/start`: idempotent client UUID,
  device UUID, extraction mode.
- POST `/v1/notebooks/:notebookId/conversations/:sessionId/events`: consecutive
  envelopes `{ sequence, id, observation }`; acknowledgement means durable receipt.
- POST `/v1/notebooks/:notebookId/conversations/:sessionId/updates`: authoritative
  conversation status and notebook snapshot; revisions/cursors reject stale reads.

Public observations are provider transcript signals, playback progress,
interruption, typed input, and session ending. No public extraction/commit events.
Clients persist an outbound queue before sending; retries reuse IDs and sequences.

## Implementation order and verification

1. Add complete reducer/assembler checkpoints, including interruption gates and
   in-flight identity; retain existing transition tests and add restart tests.
2. Implement a platform-free runtime over the existing core. Persist its checkpoint,
   consumed input cursor, and pending effects together. Persist the exact prepared
   commit before invoking Notebook Commit. Retry uncertain commits unchanged.
3. Add service-only Supabase storage RPCs: authenticated ownership, durable inbox,
   bounded batches, sequence deduplication, expiring fenced worker leases, and
   atomic checkpoints. Keep user tokens out of durable storage. Server wrappers
   derive the user from the owned session for existing snapshot/commit RPCs.
4. Add AWS HTTP and worker adapters. Wake workers after input; a scheduled sweep
   recovers missed wakeups, expired leases and due deadlines. Never depend on a
   warm Lambda's memory. External I/O runs outside DB transactions.
5. Wire web and Flutter observation queues and snapshot synchronization. Retire
   client execution of extraction and commit effects for cloud sessions.
6. Validate restart during interruption, duplicate/conflicting envelopes, out-of-order
   rejection, unknown commit outcome, revision conflict, worker lease expiry, and
   cross-user isolation. Exercise both client transports and infrastructure synthesis.

## Rollout

Apply and verify DB migration, populate the server-only Supabase credential secret,
deploy AWS, then release clients. Do not silently fall back to local writers after
cloud acceptance. Existing local turn journals must be drained with the previous
release before cutover; refuse a new cloud session when legacy unfinished work is
present. Disconnection buffers observations locally; graph processing resumes after
connectivity returns. Microphone/audio state is not transferred between devices.

## Module seams

`turn-state`: pure lifecycle rules and serializable checkpoints.
`conversation-runtime`: observation interpretation and durable effect execution.
`conversation-store`: Supabase inbox/checkpoint/lease implementation.
`conversation-client`: versioned network protocol and recoverable outbound queue.

These public interfaces are the test seams. Existing reducer tests remain regression
coverage; runtime tests exercise restart and retry through the runtime/store interface.

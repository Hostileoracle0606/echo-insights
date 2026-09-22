# Local fixes and justification summary

Date: 2026-09-19. Code snapshot: `d924f38` on `feat/supabase-auth-and-vault`.

This document records the fixes discussed and implemented during the recent PR
work, including the earlier finalized-turn changes inherited by the parent.
It distinguishes implemented behavior from unfinished architecture and release
work. Source links are relative to this file; commit IDs pin the reviewed code.

## Justification summary

The changes aim to make Lumen remember completed speech consistently, stop
interrupted audio promptly, protect provider credentials, and keep client/server
contracts aligned. Responsibilities are separated: the turn machine decides
when work is eligible, adapters perform I/O, AWS owns Flutter's Gemini
credential and extraction coordination, and Supabase owns notebook commits.

The key decisions are:

- Finalize once and check result identity, because cancellation cannot undo a
  completed write.
- Persist progress and reuse commit identities, because an interrupted response
  does not prove that a write failed.
- Use server-held credentials for extraction and temporary credentials for live
  audio, because these two Gemini operations require different credential flows.
- Use shared contract fixtures and explicit state enums to prevent avoidable
  disagreement between implementations.
- Claim an extraction atomically before generating it, because an ordinary cache
  lookup followed by a write cannot coordinate concurrent requests.
- Keep deployment and end-to-end evidence separate from unit-test success.

## Commit and merge record

| Commit | Purpose |
| --- | --- |
| `9494a16` | Finalized-turn extraction state model. |
| `d167c5f` | Activate Flutter's turn-processing session. |
| `652a5b8` | Harden secure, durable voice sessions. |
| `36683d6` | Make PR validation reproducible and align extraction context. |
| `e12c2fe` | Merge the earlier finalized-turn branch into the parent (PR #1). |
| `5871e6d` | Recover secure extraction, routing, retrieval contracts, release gates, and cloud-runtime foundation from local work. |
| `f5b9722` | Standardize the conversation role on `assistant` and surface extraction errors. |
| `550cdaf` | Add atomic extraction claims, canonical completion, client polling, tests, and recovery documentation. |
| `d924f38` | Merge `codex/recovered-runtime-contract-fixes` into the parent. |

The parent merge and its fixes were pushed to `origin/feat/supabase-auth-and-vault`.
This documentation file was written afterward and is not part of that merge.
An older safety stash was retained; it was not deleted by the recovery or merge.

## Implemented fixes

### 1. Finalized speech is the durable unit

Previously, cumulative transcript updates could each trigger extraction and a
write. Aborting an older request did not prevent a result already in flight from
being committed. The turn machine now separates replaceable interim text from
finalized turns, checks asynchronous result identities, and processes pending
turns in order. The assembler handles final transcription and turn-completion
signals arriving in either order. Flutter also initializes the machine with the
active notebook, session, and revision before processing voice events.

For “I work at Acme … my manager is Sarah,” interim prefixes no longer each
authorize a durable write. Ordered processing lets later turns see earlier
graph updates.

Sources: [state-model explanation](finalized-turn-extraction.md),
[Flutter machine](../lib/logic/turn_state.dart),
[Flutter assembler](../lib/logic/transcript_assembler.dart),
[web reducer](../src/lib/turn-state/reducer.ts),
[Flutter orchestration](../lib/providers/journal_provider.dart).

### 2. Interruption no longer treats queued audio as heard

Flutter's player can stop and discard the current audio source and start a new
playback generation. Feeding PCM is explicitly not a playback acknowledgement.
The interruption path flushes audio promptly and rejects late assistant
transcription. When the heard-text boundary is unknown, the interrupted
assistant turn is excluded from durable extraction.

This prevents Lumen from speaking buffered audio over the user or recording
unheard assistant words as conversation evidence. The conservative tradeoff is
that some actually heard assistant speech may be omitted when timing is unknown.

Sources: [PCM player](../lib/audio/pcm_player.dart),
[interruption adapter](../lib/providers/journal_provider.dart),
[player tests](../test/pcm_player_test.dart).

### 3. Durable checkpoints and commit recovery

Finalized turns are checkpointed before extraction; extracted patches are stored
before commits. Flutter's notebook journal writes complete documents atomically
and can reload them through a new process. Prepared commits retain their exact
request identity and payload for uncertain-outcome retries. Conflict handling
reloads the authoritative snapshot before replay. The effect queue waits for
work scheduled by preceding effects when draining a session.

If the app closes after a commit was sent, recovery can retry that operation
without assuming it failed and creating another entry. This builds on the
existing Supabase Notebook Commit ledger and revision checks.

Sources: [turn journal](../lib/services/turn_journal_service.dart),
[effect queue](../lib/logic/turn_effect_queue.dart),
[commit adapter](../lib/services/notebook_commit_service.dart),
[journal tests](../test/turn_journal_service_test.dart).

### 4. Centralized Flutter authentication navigation

The login screen no longer navigates to the undefined `/journal` route.
`authRedirect` in `app.dart` owns navigation between authenticated and
unauthenticated route families; authenticated entry is `/dashboard`.

Users reach a valid screen after signing in. Login UI no longer needs to know
the application's landing route, and the routing policy is independently testable.

Sources: [routing justification](flutter-auth-routing.md),
[router](../lib/app.dart), [routing tests](../test/app_router_test.dart).

### 5. Provider credentials moved out of Flutter

The authenticated AWS live-session broker issues short-lived Gemini Live
credentials after checking notebook access. Audio connects directly to Gemini.
Flutter graph extraction instead sends text and bounded context to an AWS
Lambda, which reads the permanent key from Secrets Manager and returns a patch.
Flutter's permanent-key configuration was removed. Artifact scans detect
credential names, configured secret values, and bundled environment files.

This reduces the risk that downloading the app exposes the shared provider key.
Reusing AWS authentication and secret storage avoids building a second security
mechanism. Web extraction still calls Gemini directly with a build-time key;
the Flutter security change does not establish credential-free web extraction.

Sources: [live-session design](segment-1-secure-live-sessions.md),
[Flutter extraction adapter](../lib/services/extract_graph_service.dart),
[AWS extraction handler](../infra/lambda/extract-graph/core.mjs),
[infrastructure](../infra/lib/infra-stack.ts),
[credential scanner](../scripts/production-secrets.mjs).

### 6. Conversation roles and extraction failures made explicit

Flutter sends `assistant`, while the former AWS validator accepted `agent`.
Validation and conversation types now use `user` and `assistant`; a shared
fixture containing both roles exercises the Dart serialization and runtime
contract. The old `agent` label is rejected. Flutter throws on rejected requests,
malformed responses, and exhausted transport retries instead of reporting those
failures as successful empty patches.

Assistant history no longer causes a normal extraction request to fail with 400.
An outage is distinguishable from a valid extraction finding no facts. The
downstream turn machine still drops failed extraction work; delayed durable
recovery remains future work.

Sources: [conversation fixture](../contracts/fixtures/extract-graph-v1.conversation.json),
[runtime tests](../infra/test/extract-graph.test.mjs),
[Flutter extraction tests](../test/extract_graph_service_test.dart).

### 7. Atomic extraction ownership and canonical results

The former flow was cache read → Gemini → unconditional cache write. Concurrent
requests could both miss and overwrite the same key. It is now claim → generate
→ conditionally complete. A duplicate receives the completed patch or
`409 inProgress`; Flutter polls with a separate limit of 40 waits, each capped
at two seconds. Completion writes are retried without immediately regenerating
the model result.

| Variable | Responsibility |
| --- | --- |
| `cacheKey` / `id` | Identifies user, notebook, finalized turn, and extractor version. |
| `inputHash` | Binds that identity to normalized transcript and mode. |
| `ownerToken` | Identifies the invocation allowed to complete the claim. |
| `leaseExpiresAt` | Allows takeover after a 35-second lease expires. |
| `status` | Records `pending` or `completed`. |
| `patch` | Stores the canonical completed graph result. |
| `expiresAt` | Schedules record expiry through DynamoDB TTL after seven days. |
| `retryAfterMs` | Gives the client a polling delay. |

Derived context is excluded from the hash because Flutter rebuilds it after
restart. Changed transcript or mode returns `requestIdReused`; rebuilt context
can retrieve the already-completed result. Stale owners cannot overwrite a
replacement owner's result.

For a reconnect while processing “I met Maya,” overlapping requests converge
on the stored patch. This reduces duplicate generation and inconsistent results;
it does not guarantee exactly one Gemini invocation across crashes, lease
takeover, or persistent storage failure. Guarantees also depend on record retention.

Sources: [handler](../infra/lambda/extract-graph/core.mjs),
[DynamoDB adapter](../infra/lambda/extract-graph/index.mjs),
[runtime contract](notebook-runtime-interface.md).

### 8. Explicit assistant gate states

Flutter's nullable magic strings were replaced by `_AssistantTranscriptGate`:
`accepting`, `discardingInterruptedTurn`, and `awaitingNextTurn`. This preserves
the interruption policy while making legal states explicit and typo-resistant.

Source: [Flutter machine](../lib/logic/turn_state.dart).

### 9. Retrieval contracts, context selection, and release gates

Retrieval returns versioned `{ version: 1, context, entityIds }` responses.
Shared fixtures and validators pin the shape. Flutter uses the returned IDs in
its extraction context; malformed or incompatible responses are logged and
degrade to empty retrieval. Context selection keeps relevant entity/relation
identifiers, recent conversation, and follow-up grounding under a token budget.

The release workflow deploys retrieval dependencies and tests authentication,
lexical and semantic retrieval, Flutter consumption, ownership rejection, and
fixture cleanup before its dependent unsigned iOS build. Empty fallbacks cannot
stand in for successful semantic retrieval.

This improves continuity when a user refers to an earlier person or project and
helps catch deployments that answer HTTP requests but provide no usable memory.
Versioned clients and the backend must be rolled out together.

Sources: [contract fixtures](../contracts/README.md),
[Flutter retrieval](../lib/services/retrieve_memory_service.dart),
[context compiler](../lib/services/extraction_context.dart),
[release gate](flutter-retrieval-release-gate.md),
[workflow](../.github/workflows/flutter-retrieval-release.yml).

## Recovered foundation and supporting work

The recovered commit also includes serializable TypeScript reducer/assembler
checkpoints, a platform-free conversation runtime, and a Supabase inbox/job/lease
storage migration. Their purpose is to reuse lifecycle rules across clients.
AWS conversation routes/workers and client observation queues are not wired into
the active app; shared cloud orchestration is still unfinished.

Supporting changes include reproducible dependency/configuration work, web auth
and callback changes, auth-page styling, recall-tool prompt guidance, refreshed
previews, and historical documentation formatting. These are part of the
recovered commit, but formatting and styling are not evidence of correctness
fixes. Web auth error handling and documentation inconsistencies remain review
concerns rather than resolved guarantees.

Source: [cloud implementation plan](conversation-runtime-implementation.md).

## Verification and remaining limits

Recorded checks on the implementation before merging:

- 148 Flutter tests passed, including the extraction adapter tests.
- 84 web/TypeScript tests and 7 credential-scanner tests passed.
- 17 Node Lambda tests passed, including overlapping requests, stale-result
  handling, payload reuse, rebuilt context, and completion-write retry behavior.
- Targeted Flutter analysis, infrastructure TypeScript build, CDK synthesis,
  JavaScript syntax checks, and diff whitespace checks passed.
- The merged tree matched the tested child tree; the working tree was clean
  after the merge and push.

The recorded infrastructure command emitted a Watchman permission error, so its
Jest portion is not counted here as verified. The concurrency tests inject store
behavior: they do not execute conditional expressions against live DynamoDB or
independently prove lease takeover there. CDK synthesis proves template
generation, not deployed runtime behavior.

No AWS deployment, successful deployed retrieval gate, signing, TestFlight
distribution, or physical-device validation is established by these checks.
Legacy cache-record compatibility also needs deployment review: the new claim
condition treats records without a status field as claimable.

Bounded delayed extraction recovery, queue-age monitoring, and user-visible
memory-sync status remain a [documented future addition](finalized-turn-extraction.md#potential-future-addition-bounded-extraction-recovery).
Current polling is bounded; exhausting it still reaches the existing failed-turn
path. The probability examples in that proposal are illustrative, not production
measurements.

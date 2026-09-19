/**
 * Finalized-turn extraction state model — type surface.
 *
 * This module is deliberately platform-free: no React, no Flutter, no network,
 * no database. It describes *what a turn is* and *which transitions are legal*.
 * Audio capture, playback, HTTP, and persistence live in adapters that feed
 * events in and carry effects out.
 *
 * The central invariant the whole model exists to protect:
 *
 *   Only an immutable finalized transcript may modify the canonical graph,
 *   and one finalized transcript produces at most one durable turn.
 */

import type { ExtractGraphResult } from "@/lib/extract-graph";

export type Speaker = "user" | "assistant";

/**
 * Phase of the *replaceable* turn currently being collected.
 *
 * `awaitingFinal` exists because Gemini Live gives no ordering guarantee
 * between the final input transcription and the turn-completion signal
 * (see docs/streaming-extraction-correctness-research.md). A turn that has
 * completed but has no authoritative text yet waits here rather than
 * finalizing on whatever interim text happened to have arrived.
 */
export type ActivePhase = "listening" | "interim" | "awaitingFinal";

/** Durable checkpoint stages. Persisted, so a restart resumes rather than repeats. */
export type DurableStage =
  | "finalRecorded"
  | "extracting"
  | "extracted"
  | "commitPending"
  | "committed"
  | "failed";

/**
 * Full identity of an asynchronous operation. Every awaited result carries one
 * and must match the live turn on *all five* fields before it may change
 * anything. Cancellation is only a resource optimization; this is the
 * correctness rule.
 */
export interface TurnIdentity {
  sessionId: string;
  notebookId: string;
  turnId: string;
  transcriptVersion: number;
  generation: number;
}

/** Display-only result of a provisional extraction. Never touches the graph. */
export interface ExtractionPreview {
  turnId: string;
  entityNames: string[];
  relationLabels: string[];
}

/**
 * The exact Notebook Commit input produced by one merge.
 *
 * It is checkpointed before the request is sent. An unknown-outcome retry must
 * reuse this value verbatim; only a confirmed revision conflict may discard it
 * and prepare a new attempt against the reloaded snapshot.
 */
export interface PreparedCommit {
  expectedRevision: number;
  change: unknown;
  entryId: string;
  tempFollowUpId?: string;
}

export interface ActiveTurn {
  turnId: string;
  speaker: Speaker;
  phase: ActivePhase;
  /** Replaceable display text. Superseded wholesale by each interim update. */
  text: string;
  /** Increments on every replacement of `text`. */
  transcriptVersion: number;
  /** Increments whenever previously-started async work for this turn is invalidated. */
  generation: number;
  /** Authoritative text, if a final transcription arrived. */
  finalText: string | null;
  /** True once the provider signalled the turn is over. */
  turnCompleted: boolean;
  /**
   * Assistant only: number of characters of `text` confirmed *played to the
   * user*. `null` means the boundary is unknown — an interrupted turn with an
   * unknown boundary is never durably extracted.
   */
  heardChars: number | null;
  interrupted: boolean;
  startedAt: string;
}

/**
 * An immutable finalized transcript plus its durable processing state.
 * `commitRequestId` is minted once, at finalization, and reused for every
 * commit attempt of this turn — including attempts after a revision conflict.
 */
export interface FinalizedTurn {
  turnId: string;
  sessionId: string;
  notebookId: string;
  speaker: Speaker;
  /** Immutable. Never edited after finalization. */
  transcript: string;
  transcriptVersion: number;
  transcriptHash: string;
  /** Makes prompt/schema/model changes explicit during replay. */
  extractorVersion: string;
  generation: number;
  commitRequestId: string;
  stage: DurableStage;
  extraction: ExtractGraphResult | null;
  /** Present once the client has merged and checkpointed the exact RPC input. */
  preparedCommit?: PreparedCommit | null;
  baseRevision: number | null;
  revision: number | null;
  finalizedAt: string;
  /** Set when the turn is finalized from a partially-heard assistant response. */
  truncatedFromInterruption: boolean;
}

export interface ConversationTurn {
  turnId: string;
  role: Speaker;
  text: string;
  createdAt: string;
}

export interface TurnMachineState {
  sessionId: string | null;
  notebookId: string | null;
  /** At most one in-progress (still collecting) turn per speaker. */
  active: { user: ActiveTurn | null; assistant: ActiveTurn | null };
  /**
   * Turns the provider has marked complete that are still waiting for an
   * authoritative final transcription. Held separately from `active` so a
   * following turn's interim text cannot displace a turn mid-finalization.
   */
  awaiting: { user: ActiveTurn | null; assistant: ActiveTurn | null };
  /** Finalized turns awaiting or undergoing durable processing, in original order. */
  pending: FinalizedTurn[];
  /** Canonical conversation history. Finalized, heard text only. */
  conversation: ConversationTurn[];
  /** Display-only. Cleared whenever the turn it described is superseded. */
  preview: ExtractionPreview | null;
  /** Observability: results rejected because their identity no longer matched. */
  staleRejections: number;
  /** Last committed notebook revision the machine has observed. */
  revision: number;
}

export type TurnEvent =
  | { type: "sessionStarted"; sessionId: string; notebookId: string }
  | { type: "sessionEnded" }
  /** Replaces the active turn's display text wholesale. */
  | { type: "interimTranscript"; speaker: Speaker; text: string }
  /** Authoritative transcription. May arrive before or after `turnCompleted`. */
  | { type: "finalTranscript"; speaker: Speaker; text: string }
  | { type: "turnCompleted"; speaker: Speaker }
  /** Adapter-scheduled fallback when no final transcription follows completion. */
  | { type: "finalizationDeadline"; speaker: Speaker; turnId: string }
  /** Assistant playback watermark: characters confirmed heard. */
  | { type: "playbackAdvanced"; heardChars: number }
  /** Barge-in. `heardChars: null` means the boundary could not be determined. */
  | { type: "assistantInterrupted"; heardChars: number | null }
  | { type: "provisionalExtractionSettled"; key: TurnIdentity; preview: ExtractionPreview }
  | { type: "durableExtractionSucceeded"; key: TurnIdentity; payload: ExtractGraphResult }
  | { type: "durableExtractionFailed"; key: TurnIdentity; message: string }
  | { type: "commitStarted"; turnId: string; baseRevision: number }
  | { type: "commitCommitted"; turnId: string; commitRequestId: string; revision: number }
  | { type: "commitConflict"; turnId: string; currentRevision: number }
  /** Authoritative snapshot reloaded after a conflict; pending turns may replay. */
  | { type: "snapshotReloaded"; revision: number }
  /** Transport failed after the request left; the outcome is genuinely unknown. */
  | { type: "commitUnknown"; turnId: string }
  | { type: "commitRejected"; turnId: string; code: string }
  /** Recovery: durable turns loaded from the turn journal at startup. */
  | { type: "restored"; turns: FinalizedTurn[] };

export type TurnEffect =
  /** Stop work that can no longer change anything. Optimization, not correctness. */
  | { type: "cancelExtraction"; turnId: string; generation: number }
  | { type: "startProvisionalExtraction"; key: TurnIdentity; text: string }
  | { type: "startDurableExtraction"; key: TurnIdentity; transcript: string }
  | { type: "startCommit"; turnId: string; commitRequestId: string }
  /** Reload the authoritative snapshot, then replay `pending` in order. */
  | { type: "reloadSnapshot"; turnId: string }
  | { type: "scheduleFinalizationDeadline"; speaker: Speaker; turnId: string }
  /** Write the durable checkpoint before the next irreversible step. */
  | { type: "persistTurn"; turn: FinalizedTurn }
  | { type: "forgetTurn"; turnId: string }
  | { type: "flushPlayback" };

export interface TurnMachineDeps {
  now: () => string;
  newTurnId: () => string;
  newRequestId: () => string;
  /** Proves which exact immutable text produced an extraction. */
  hash?: (text: string) => string;
  extractorVersion?: string;
  /** Provisional extraction is optional and display-only. Off by default. */
  provisionalExtraction?: boolean;
}

export interface TurnMachine {
  readonly state: TurnMachineState;
  checkpoint: () => TurnCheckpoint;
  /** Applies one event. Returns the effects the adapter should carry out. */
  dispatch: (event: TurnEvent) => TurnEffect[];
}

/** Complete process-independent state, including gates hidden from the UI. */
export interface TurnCheckpoint {
  version: 1;
  state: TurnMachineState;
  inFlight: string | null;
  assistantGate: "collecting" | "awaitingNewTurn" | null;
}

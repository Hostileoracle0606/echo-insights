/**
 * Executes turn-machine effects against real ports.
 *
 * The machine decides *what* must happen; this module performs it and feeds the
 * outcome back in as an event. Everything that touches the network, the model,
 * or storage lives behind `TurnPorts`, so the whole durable pipeline —
 * including crash recovery and idempotent retry — is testable with in-memory
 * fakes and no React, no HTTP and no database.
 */

import type { ExtractGraphResult } from "@/lib/extract-graph";

import type {
  ExtractionPreview,
  FinalizedTurn,
  Speaker,
  TurnEffect,
  TurnEvent,
  TurnIdentity,
  TurnMachine,
} from "./types";

/** The subset of the Notebook Commit outcome this pipeline reacts to. */
export type PipelineCommitOutcome =
  | { status: "committed"; requestId: string; revision: number }
  | { status: "conflict"; currentRevision: number }
  | { status: "rejected"; code: string };

export interface TurnJournalStore {
  /** Durable checkpoints for turns that have not finished committing. */
  save: (turn: FinalizedTurn) => Promise<void>;
  remove: (turnId: string) => Promise<void>;
  load: (notebookId: string) => Promise<FinalizedTurn[]>;
}

export interface TurnPorts {
  /** Runs the extractor. Must honour `signal` for cancellation. */
  extract: (
    transcript: string,
    key: TurnIdentity,
    signal: AbortSignal,
  ) => Promise<ExtractGraphResult>;
  /** Performs one Notebook Commit. Rejects only on transport failure. */
  commit: (turn: FinalizedTurn) => Promise<PipelineCommitOutcome>;
  reloadSnapshot: (notebookId: string) => Promise<{ revision: number } | null>;
  journal: TurnJournalStore;
  scheduleDeadline: (speaker: Speaker, turnId: string, fire: () => void) => void;
  /** Applies a committed turn to the caller's local graph. */
  onCommitted?: (turn: FinalizedTurn) => void;
  /** Display-only provisional preview. Must never touch canonical state. */
  onPreview?: (preview: ExtractionPreview | null) => void;
  onProvisional?: (
    text: string,
    key: TurnIdentity,
    signal: AbortSignal,
  ) => Promise<ExtractionPreview>;
  flushPlayback?: () => void;
  onError?: (message: string) => void;
}

export interface TurnPipeline {
  /** Dispatches an event and settles once all work it triggered has finished. */
  dispatch: (event: TurnEvent) => Promise<void>;
}

export function createTurnPipeline(machine: TurnMachine, ports: TurnPorts): TurnPipeline {
  /** One controller per in-flight extraction, keyed by turn id. */
  const controllers = new Map<string, { generation: number; controller: AbortController }>();

  function abortFor(turnId: string): void {
    const entry = controllers.get(turnId);
    if (!entry) return;
    entry.controller.abort();
    controllers.delete(turnId);
  }

  function isAbort(error: unknown): boolean {
    if (error instanceof DOMException && error.name === "AbortError") return true;
    return error instanceof Error && error.message.toLowerCase().includes("abort");
  }

  async function run(event: TurnEvent): Promise<void> {
    const effects = machine.dispatch(event);
    await Promise.all(effects.map(perform));
  }

  async function perform(effect: TurnEffect): Promise<void> {
    switch (effect.type) {
      case "persistTurn":
        await ports.journal.save(effect.turn);
        return;

      case "forgetTurn":
        abortFor(effect.turnId);
        await ports.journal.remove(effect.turnId);
        return;

      case "cancelExtraction":
        // Purely an optimization. Correctness comes from the identity checks
        // the machine performs when the result finally arrives.
        abortFor(effect.turnId);
        return;

      case "flushPlayback":
        ports.flushPlayback?.();
        return;

      case "scheduleFinalizationDeadline":
        ports.scheduleDeadline(effect.speaker, effect.turnId, () => {
          void run({
            type: "finalizationDeadline",
            speaker: effect.speaker,
            turnId: effect.turnId,
          });
        });
        return;

      case "startProvisionalExtraction": {
        if (!ports.onProvisional) return;
        abortFor(effect.key.turnId);
        const controller = new AbortController();
        controllers.set(effect.key.turnId, {
          generation: effect.key.generation,
          controller,
        });
        try {
          const preview = await ports.onProvisional(effect.text, effect.key, controller.signal);
          await run({ type: "provisionalExtractionSettled", key: effect.key, preview });
          ports.onPreview?.(machine.state.preview);
        } catch (error) {
          if (!isAbort(error)) ports.onError?.(messageOf(error));
        }
        return;
      }

      case "startDurableExtraction": {
        const controller = new AbortController();
        controllers.set(effect.key.turnId, {
          generation: effect.key.generation,
          controller,
        });
        try {
          const result = await ports.extract(effect.transcript, effect.key, controller.signal);
          await run({ type: "durableExtractionSucceeded", key: effect.key, payload: result });
        } catch (error) {
          if (isAbort(error)) {
            // A cancelled durable extraction still needs the turn resolved, or
            // the queue stalls behind it.
            await run({
              type: "durableExtractionFailed",
              key: effect.key,
              message: "aborted",
            });
            return;
          }
          ports.onError?.(messageOf(error));
          await run({
            type: "durableExtractionFailed",
            key: effect.key,
            message: messageOf(error),
          });
        }
        return;
      }

      case "startCommit": {
        const turn = machine.state.pending.find((t) => t.turnId === effect.turnId);
        if (!turn) return;
        let outcome: PipelineCommitOutcome;
        try {
          outcome = await ports.commit(turn);
        } catch {
          // Transport failure: the outcome is genuinely unknown. Retry the
          // identical request with the SAME request id — the server ledger
          // replays it if it already committed and applies it once otherwise.
          await run({ type: "commitUnknown", turnId: effect.turnId });
          return;
        }
        if (outcome.status === "committed") {
          ports.onCommitted?.({ ...turn, stage: "committed", revision: outcome.revision });
          await run({
            type: "commitCommitted",
            turnId: effect.turnId,
            commitRequestId: outcome.requestId,
            revision: outcome.revision,
          });
          return;
        }
        if (outcome.status === "conflict") {
          await run({
            type: "commitConflict",
            turnId: effect.turnId,
            currentRevision: outcome.currentRevision,
          });
          return;
        }
        ports.onError?.(`commit rejected: ${outcome.code}`);
        await run({ type: "commitRejected", turnId: effect.turnId, code: outcome.code });
        return;
      }

      case "reloadSnapshot": {
        const notebookId = machine.state.notebookId;
        if (!notebookId) return;
        const snapshot = await ports.reloadSnapshot(notebookId);
        if (!snapshot) return;
        // Pending turns replay over the fresh snapshot in their original order,
        // keeping the request ids they were minted with.
        await run({ type: "snapshotReloaded", revision: snapshot.revision });
        return;
      }

      default:
        return;
    }
  }

  return { dispatch: run };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

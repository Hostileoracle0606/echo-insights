import { createTurnMachine } from "../turn-state/reducer";
import { createTranscriptAssembler, type AssemblerCheckpoint } from "../turn-state/transcript-assembler";
import type { TurnCheckpoint, TurnEffect, TurnEvent, TurnMachineDeps, FinalizedTurn, PreparedCommit } from "../turn-state/types";
import type { TurnPorts } from "../turn-state/pipeline";
import type { Envelope, Observation } from "./contract";

export interface Job {
  id: string; effect: TurnEffect; due: number; attempts: number;
  prepared?: PreparedCommit;
}
export interface RuntimeCheckpoint {
  version: 1; turn: TurnCheckpoint; assembler: AssemblerCheckpoint;
  cursor: number; ended: boolean; jobs: Job[]; error: string | null;
}
export type RuntimePorts = Pick<TurnPorts, "extract" | "prepareCommit" | "commit" | "reloadSnapshot"> & {
  /** Must atomically store the complete document under a valid fenced lease. */
  save: (checkpoint: RuntimeCheckpoint) => Promise<void>;
};

export function createConversationRuntime(
  deps: TurnMachineDeps,
  ports: RuntimePorts,
  initial: { sessionId: string; notebookId: string; revision: number },
  restored?: RuntimeCheckpoint,
) {
  if (restored && restored.version !== 1) throw new Error("Unsupported runtime checkpoint");
  const machine = createTurnMachine(deps, restored?.turn);
  const assembler = createTranscriptAssembler(restored?.assembler);
  let cursor = restored?.cursor ?? 0;
  let ended = restored?.ended ?? false;
  let jobs: Job[] = structuredClone(restored?.jobs ?? []);
  let error: string | null = restored?.error ?? null;
  if (!restored) {
    machine.dispatch({ type: "sessionStarted", ...initial });
    machine.dispatch({ type: "snapshotReloaded", revision: initial.revision });
  }
  const now = () => Date.parse(deps.now());
  const checkpoint = (): RuntimeCheckpoint => structuredClone({
    version: 1, turn: machine.checkpoint(), assembler: assembler.checkpoint(), cursor, ended, jobs, error,
  });
  function dispatch(event: TurnEvent) {
    for (const effect of machine.dispatch(event)) {
      // The whole turn checkpoint is already in the same transaction as its
      // outbox. Playback happens immediately on the originating device.
      if (["persistTurn", "forgetTurn", "flushPlayback", "cancelExtraction"].includes(effect.type)) continue;
      if (effect.type === "startProvisionalExtraction") continue;
      jobs.push({ id: deps.newRequestId(), effect, attempts: 0,
        due: now() + (effect.type === "scheduleFinalizationDeadline" ? 1500 : 0) });
    }
  }
  function observe(observation: Observation) {
    if (ended) return; // Retry of a closed producer cannot reopen this session.
    switch (observation.type) {
      case "userChunk": case "userInterim": case "userFinal":
      case "assistantChunk": case "assistantFinal":
        assembler[observation.type](observation.text).forEach(dispatch); break;
      case "turnComplete": assembler.turnComplete().forEach(dispatch); break;
      case "interrupted": assembler.interrupted(observation.heardChars).forEach(dispatch); break;
      case "playback": dispatch({ type: "playbackAdvanced", heardChars: observation.heardChars }); break;
      case "typed":
        dispatch({ type: "finalTranscript", speaker: "user", text: observation.text });
        dispatch({ type: "turnCompleted", speaker: "user" }); break;
      case "end":
        dispatch({ type: "sessionEnded" }); assembler.reset(); ended = true; break;
    }
  }
  return {
    checkpoint,
    async accept(events: Envelope[]) {
      for (const event of events) {
        if (event.sequence <= cursor) continue;
        if (event.sequence !== cursor + 1) throw new Error("Event sequence gap");
        observe(event.observation); cursor = event.sequence;
      }
      await ports.save(checkpoint());
    },
    async work(): Promise<boolean> {
      const job = jobs.find((item) => item.due <= now());
      if (!job) return false;
      const effect = job.effect;
      let result: TurnEvent | null = null;
      try {
        switch (effect.type) {
          case "scheduleFinalizationDeadline":
            result = { type: "finalizationDeadline", speaker: effect.speaker, turnId: effect.turnId }; break;
          case "startDurableExtraction": {
            const payload = await ports.extract(effect.transcript, effect.key, AbortSignal.timeout(25000));
            result = { type: "durableExtractionSucceeded", key: effect.key, payload }; break;
          }
          case "startCommit": {
            const turn = machine.state.pending.find((t) => t.turnId === effect.turnId);
            if (!turn) break;
            if (!job.prepared) {
              job.prepared = await ports.prepareCommit(turn);
              // Save failure MUST escape before any irreversible I/O.
              await ports.save(checkpoint());
            }
            const outcome = await ports.commit(turn, job.prepared);
            if (outcome.status === "committed") {
              result = { type: "commitCommitted", turnId: turn.turnId,
                commitRequestId: outcome.requestId, revision: outcome.revision };
            } else if (outcome.status === "conflict") {
              result = { type: "commitConflict", turnId: turn.turnId, currentRevision: outcome.currentRevision };
            } else {
              // Keep the checkpoint visible for recovery instead of silently
              // dropping a finalized turn on a permanent domain rejection.
              throw new Error("Commit rejected");
            }
            break;
          }
          case "reloadSnapshot": {
            const snapshot = await ports.reloadSnapshot(initial.notebookId);
            if (!snapshot) throw new Error("Notebook unavailable");
            result = { type: "snapshotReloaded", revision: snapshot.revision }; break;
          }
        }
      } catch {
        job.attempts += 1;
        job.due = now() + Math.min(60000, 1000 * 2 ** Math.min(job.attempts, 6));
        error = "processingRetry";
        // Includes the exact prepared commit. Unknown outcomes repeat it.
        await ports.save(checkpoint());
        return false;
      }
      jobs = jobs.filter((item) => item.id !== job.id);
      error = null;
      if (result) dispatch(result);
      await ports.save(checkpoint());
      return true;
    },
  };
}

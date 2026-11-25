// One "app process" for the recovery eval: the web app's own turn machine,
// pipeline and web adapter (merge, prepare, commit, snapshot reload), wired
// the way src/routes/index.tsx wires them. Only the ends are swapped:
//  - extraction goes to the API Gateway route both apps call
//    (POST /v1/notebooks/{id}/extractions), answered in-process;
//  - the turn journal lives in a per-device storage object that outlives the
//    process, as localStorage outlives a killed tab;
//  - each finalized turn is saved to conversation_turns the way the iOS app's
//    TranscriptStore does (upsert, duplicates ignored).
// Dropping the object without awaiting it is a process kill.
import { randomUUID } from "node:crypto";

import type { ExtractGraphResult } from "@/lib/extract-graph";
import { mergeExtraction, type ExtractedPayload } from "@/lib/journal-store";
import type { JournalState } from "@/lib/journal-types";
import { getNotebookSnapshot } from "@/lib/notebook-commit";
import { supabase } from "@/lib/supabase/browser";
import { createTurnPipeline, type TurnPipeline } from "@/lib/turn-state/pipeline";
import { createTurnMachine } from "@/lib/turn-state/reducer";
import type { TurnMachine } from "@/lib/turn-state/types";
import { createLocalTurnJournal, createWebTurnPorts } from "@/lib/turn-state/web-adapter";

export const GATEWAY = "http://gateway.recovery-eval.invalid";
export const EXTRACTOR_VERSION = "recovery-eval/v1";

export type DeviceStorage = Pick<Storage, "getItem" | "setItem">;

export function deviceStorage(): DeviceStorage {
  const items = new Map<string, string>();
  return {
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => void items.set(key, value),
  };
}

const emptyState = (): JournalState => ({
  entries: [],
  entities: {},
  relations: {},
  followUps: [],
  askedQuestions: [],
});

export interface EvalClient {
  machine: TurnMachine;
  pipeline: TurnPipeline;
  /** Startup: snapshot, then resume anything left in the turn journal. */
  boot: () => Promise<{ resumed: number }>;
  /** One typed user turn, finalized and processed end to end. */
  speak: (text: string) => Promise<void>;
  errors: string[];
}

export function createEvalClient(opts: {
  token: string;
  notebookId: string;
  storage: DeviceStorage;
  fetchImpl: typeof fetch;
}): EvalClient {
  let state = emptyState();
  let revision = 0;
  const errors: string[] = [];
  const journal = createLocalTurnJournal(opts.storage);

  const machine = createTurnMachine({
    now: () => new Date().toISOString(),
    newTurnId: () => randomUUID(),
    newRequestId: () => randomUUID(),
    extractorVersion: EXTRACTOR_VERSION,
  });

  const ports = createWebTurnPorts({
    getState: () => state,
    getConversation: () => [],
    getExtractionMode: () => "wiki",
    getRevision: () => revision,
    setRevision: (next) => {
      revision = next;
    },
    replaceState: (next) => {
      state = next;
    },
    mergeForCommit: (transcript, payload) => {
      // As index.tsx: the extractor's follow-up never reaches the merge.
      const graphOnly = { ...payload, followUp: undefined } as ExtractedPayload;
      const merged = mergeExtraction(state, transcript, graphOnly);
      state = merged.next;
      return { change: merged.change, entryId: merged.entryId };
    },
    onCommitted: ({ entryId, ids }) => {
      if (!ids.entryId) return;
      state = {
        ...state,
        entries: state.entries.map((e) => (e.id === entryId ? { ...e, id: ids.entryId! } : e)),
      };
    },
    onError: (message) => errors.push(message),
    scheduleDeadline: () => {},
  });

  ports.journal = {
    ...journal,
    async save(turn) {
      const first = (await journal.load(turn.notebookId)).every((t) => t.turnId !== turn.turnId);
      await journal.save(turn); // durable first, synchronously, like localStorage
      if (first && turn.stage === "finalRecorded") {
        const { error } = await supabase.from("conversation_turns").upsert(
          {
            notebook_id: turn.notebookId,
            turn_id: turn.turnId,
            speaker: turn.speaker,
            text: turn.transcript,
            spoken_at: turn.finalizedAt,
            input: "typed",
          },
          { onConflict: "notebook_id,turn_id", ignoreDuplicates: true },
        );
        if (error) errors.push(`conversation_turns: ${error.message}`);
      }
    },
  };

  ports.extract = async (transcript, key, signal): Promise<ExtractGraphResult> => {
    const response = await opts.fetchImpl(`${GATEWAY}/v1/notebooks/${key.notebookId}/extractions`, {
      method: "POST",
      headers: { authorization: `Bearer ${opts.token}`, "content-type": "application/json" },
      body: JSON.stringify({
        turnId: key.turnId,
        extractorVersion: EXTRACTOR_VERSION,
        mode: "wiki",
        text: transcript,
        context: { entities: [], relations: [], recentConversation: [] },
      }),
      signal,
    });
    const body = (await response.json().catch(() => null)) as { patch?: ExtractGraphResult } | null;
    if (!response.ok || !body?.patch) throw new Error(`extraction failed: ${response.status}`);
    return { ...body.patch, followUp: undefined as unknown as ExtractGraphResult["followUp"] };
  };

  const pipeline = createTurnPipeline(machine, ports);

  return {
    machine,
    pipeline,
    errors,
    async boot() {
      const snapshot = await getNotebookSnapshot(opts.notebookId);
      if (snapshot) {
        state = snapshot.state;
        revision = snapshot.revision;
      }
      await pipeline.dispatch({ type: "sessionStarted", sessionId: `restore-${opts.notebookId}`, notebookId: opts.notebookId });
      await pipeline.dispatch({ type: "snapshotReloaded", revision: snapshot?.revision ?? 0 });
      const unfinished = await journal.load(opts.notebookId);
      if (unfinished.length > 0) await pipeline.dispatch({ type: "restored", turns: unfinished });
      return { resumed: unfinished.length };
    },
    async speak(text) {
      await pipeline.dispatch({ type: "interimTranscript", speaker: "user", text });
      await pipeline.dispatch({ type: "turnCompleted", speaker: "user" });
      await pipeline.dispatch({ type: "finalTranscript", speaker: "user", text });
    },
  };
}

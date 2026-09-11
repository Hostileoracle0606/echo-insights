import { describe, expect, it, vi } from "vitest";

import type { ExtractGraphResult } from "@/lib/extract-graph";

import { createTurnPipeline, type TurnPorts } from "./pipeline";
import { createTurnMachine } from "./reducer";
import type { FinalizedTurn } from "./types";

const payload = (name: string): ExtractGraphResult => ({
  entities: [{ name, type: "organization" }],
  relations: [],
  followUp: { question: "", reason: "", targetEntityNames: [] },
});

/**
 * In-memory stand-in for `public.commit_notebook`, mirroring its real rules:
 *  - the idempotency ledger records ONLY committed outcomes;
 *  - an exact replay (same request id + same payload hash) returns the stored
 *    result without re-applying;
 *  - the same request id with different input is rejected as requestIdReused;
 *  - a conflict performs no write and records nothing.
 */
function fakeNotebookServer() {
  let revision = 0;
  const ledger = new Map<string, { hash: string; result: unknown }>();
  const applied: string[] = [];

  return {
    applied,
    get revision() {
      return revision;
    },
    /** Simulates another device committing to the same notebook. */
    commitElsewhere() {
      revision += 1;
    },
    commit(turn: FinalizedTurn) {
      const hash = JSON.stringify({
        change: turn.extraction,
        expectedRevision: turn.baseRevision,
      });
      const prior = ledger.get(turn.commitRequestId);
      if (prior) {
        if (prior.hash === hash) return prior.result as never;
        return { status: "rejected", code: "requestIdReused" } as never;
      }
      if (turn.baseRevision !== revision) {
        return { status: "conflict", currentRevision: revision } as never;
      }
      revision += 1;
      applied.push(turn.transcript);
      const result = {
        status: "committed",
        requestId: turn.commitRequestId,
        revision,
      };
      ledger.set(turn.commitRequestId, { hash, result });
      return result as never;
    },
  };
}

function journalStore() {
  const rows = new Map<string, FinalizedTurn>();
  return {
    rows,
    save: vi.fn(async (turn: FinalizedTurn) => {
      rows.set(turn.turnId, turn);
    }),
    remove: vi.fn(async (turnId: string) => {
      rows.delete(turnId);
    }),
    load: vi.fn(async () => [...rows.values()]),
  };
}

function harness(over: Partial<TurnPorts> = {}) {
  let turnSeq = 0;
  let reqSeq = 0;
  let clock = 0;
  const machine = createTurnMachine({
    now: () => new Date(1_700_000_000_000 + clock++ * 1000).toISOString(),
    newTurnId: () => `turn-${++turnSeq}`,
    newRequestId: () => `req-${++reqSeq}`,
  });
  const server = fakeNotebookServer();
  const journal = journalStore();
  const extract = vi.fn(async (transcript: string) => payload(transcript.slice(0, 8)));
  const ports: TurnPorts = {
    extract,
    commit: async (turn) => server.commit(turn),
    reloadSnapshot: async () => ({ revision: server.revision }),
    journal,
    scheduleDeadline: () => {},
    ...over,
  };
  const pipeline = createTurnPipeline(machine, ports);
  return { machine, pipeline, server, journal, extract, ports };
}

/** Lets every pending microtask and timer-zero callback settle. */
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Speaks one complete user turn end to end. */
async function speak(pipeline: ReturnType<typeof harness>["pipeline"], text: string) {
  await pipeline.dispatch({ type: "interimTranscript", speaker: "user", text });
  await pipeline.dispatch({ type: "turnCompleted", speaker: "user" });
  await pipeline.dispatch({ type: "finalTranscript", speaker: "user", text });
}

describe("durable turn pipeline", () => {
  it("extracts once and commits once for a finalized turn", async () => {
    const h = harness();
    await h.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    await speak(h.pipeline, "I work at Acme.");

    expect(h.extract).toHaveBeenCalledTimes(1);
    expect(h.server.applied).toEqual(["I work at Acme."]);
    expect(h.journal.rows.size).toBe(0); // cleared once durable
  });

  it("a crash after extraction but before commit reuses the stored extraction", async () => {
    // First process: extraction succeeds, then the process dies before the
    // commit ever returns (modelled as a commit that never settles).
    const first = harness({ commit: () => new Promise(() => {}) });
    await first.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    await first.pipeline.dispatch({
      type: "interimTranscript",
      speaker: "user",
      text: "I work at Acme.",
    });
    await first.pipeline.dispatch({ type: "turnCompleted", speaker: "user" });
    void first.pipeline.dispatch({
      type: "finalTranscript",
      speaker: "user",
      text: "I work at Acme.",
    });
    await flush();

    expect(first.extract).toHaveBeenCalledTimes(1);
    const checkpoint = [...first.journal.rows.values()];
    expect(checkpoint).toHaveLength(1);
    expect(checkpoint[0].extraction).not.toBeNull();

    // Restart: a fresh machine and pipeline, handed the journal contents.
    const second = harness();
    await second.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    await second.pipeline.dispatch({ type: "restored", turns: checkpoint });

    expect(second.extract).not.toHaveBeenCalled();
    expect(second.server.applied).toEqual(["I work at Acme."]);
  });

  it("a lost commit response is retried with the same request id and applies once", async () => {
    const server = fakeNotebookServer();
    let attempts = 0;
    const h = harness({
      commit: async (turn) => {
        attempts += 1;
        const outcome = server.commit(turn);
        // The server committed; the response never made it back.
        if (attempts === 1) throw new Error("network dropped");
        return outcome;
      },
      reloadSnapshot: async () => ({ revision: server.revision }),
    });
    await h.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    await speak(h.pipeline, "I work at Acme.");

    expect(attempts).toBe(2);
    // Applied exactly once despite two attempts: the ledger replayed the second.
    expect(server.applied).toEqual(["I work at Acme."]);
    expect(h.machine.state.pending).toHaveLength(0);
    expect(h.journal.rows.size).toBe(0);
  });

  it("replays two pending turns in order after a revision conflict, reusing request ids", async () => {
    const h = harness();
    await h.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    // Another device commits first, so our first attempt conflicts.
    h.server.commitElsewhere();

    await speak(h.pipeline, "I work at Acme.");
    await speak(h.pipeline, "My manager is Sarah.");

    expect(h.server.applied).toEqual(["I work at Acme.", "My manager is Sarah."]);
    expect(h.machine.state.pending).toHaveLength(0);
    // Each turn extracted exactly once — a conflict must not re-run the model.
    expect(h.extract).toHaveBeenCalledTimes(2);
  });

  it("does not apply an extraction whose notebook was replaced mid-flight", async () => {
    let release: ((value: ExtractGraphResult) => void) | null = null;
    const h = harness({
      extract: vi.fn(
        () =>
          new Promise<ExtractGraphResult>((resolve) => {
            release = resolve;
          }),
      ),
    });
    await h.pipeline.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    await h.pipeline.dispatch({
      type: "interimTranscript",
      speaker: "user",
      text: "I work at Acme.",
    });
    await h.pipeline.dispatch({ type: "turnCompleted", speaker: "user" });
    void h.pipeline.dispatch({
      type: "finalTranscript",
      speaker: "user",
      text: "I work at Acme.",
    });
    await flush();
    expect(release).not.toBeNull();

    // Notebook switched while the extractor was still running.
    await h.pipeline.dispatch({ type: "sessionStarted", sessionId: "s2", notebookId: "nb2" });
    release!(payload("Acme"));
    await flush();

    expect(h.server.applied).toEqual([]);
    expect(h.machine.state.staleRejections).toBeGreaterThan(0);
  });
});

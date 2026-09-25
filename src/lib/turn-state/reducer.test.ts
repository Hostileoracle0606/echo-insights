import { describe, expect, it } from "vitest";

import type { ExtractGraphResult } from "@/lib/extract-graph";

import { createTurnMachine } from "./reducer";

/** Deterministic ids so assertions can name them. */
function machine(opts: { provisionalExtraction?: boolean } = {}) {
  let turnSeq = 0;
  let reqSeq = 0;
  let clock = 0;
  return createTurnMachine({
    now: () => new Date(1_700_000_000_000 + clock++ * 1000).toISOString(),
    newTurnId: () => `turn-${++turnSeq}`,
    newRequestId: () => `req-${++reqSeq}`,
    ...opts,
  });
}

const payload = (name: string): ExtractGraphResult => ({
  entities: [{ name, type: "organization" }],
  relations: [],
  // Gemini owns dialogue; the extractor's follow-up is suppressed downstream.
  followUp: { question: "", reason: "", targetEntityNames: [] },
});

describe("process-independent checkpoints", () => {
  function restore(original: ReturnType<typeof machine>) {
    return createTurnMachine({
      now: () => "2026-09-18T00:00:00.000Z",
      newTurnId: () => "restored-new-turn",
      newRequestId: () => "restored-new-request",
    }, JSON.parse(JSON.stringify(original.checkpoint())));
  }

  it("keeps the interruption gate across a process restart", () => {
    const first = machine();
    first.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    first.dispatch({ type: "interimTranscript", speaker: "assistant", text: "Never heard." });
    first.dispatch({ type: "assistantInterrupted", heardChars: null });
    const second = restore(first);
    second.dispatch({ type: "turnCompleted", speaker: "assistant" });
    second.dispatch({ type: "finalTranscript", speaker: "assistant", text: "Never heard." });
    expect(second.state.pending).toEqual([]);
    expect(second.state.conversation).toEqual([]);
  });

  it("does not restart in-flight extraction when another turn arrives after restart", () => {
    const first = machine();
    first.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    first.dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." });
    const effects = first.dispatch({ type: "turnCompleted", speaker: "user" });
    const extraction = effects.find((effect) => effect.type === "startDurableExtraction")!;
    if (extraction.type !== "startDurableExtraction") throw new Error("Missing extraction");
    const second = restore(first);
    second.dispatch({ type: "finalTranscript", speaker: "user", text: "I know Maya." });
    const more = second.dispatch({ type: "turnCompleted", speaker: "user" });
    expect(more.some((effect) => effect.type === "startDurableExtraction")).toBe(false);
    const settled = second.dispatch({ type: "durableExtractionSucceeded", key: extraction.key, payload: payload("Acme") });
    expect(settled.some((effect) => effect.type === "startCommit")).toBe(true);
    expect(second.state.pending).toHaveLength(2);
    expect(first.state.pending).toHaveLength(1);
  });
});

describe("interim transcripts", () => {
  it("treats interim text as replaceable display state and bumps the version", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acne." });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });

    const active = m.state.active.user!;
    expect(active.text).toBe("I work at Acme.");
    expect(active.transcriptVersion).toBe(2);
    expect(m.state.pending).toHaveLength(0);
  });
});

describe("finalization", () => {
  it("produces exactly one durable turn from cumulative transcript prefixes", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({
      type: "interimTranscript",
      speaker: "user",
      text: "I work at Acme. My manager is Sarah.",
    });
    m.dispatch({
      type: "finalTranscript",
      speaker: "user",
      text: "I work at Acme. My manager is Sarah.",
    });
    m.dispatch({ type: "turnCompleted", speaker: "user" });

    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("I work at Acme. My manager is Sarah.");
    expect(m.state.pending[0].stage).toBe("finalRecorded");
    expect(m.state.active.user).toBeNull();
  });

  it("finalizes when the final transcription arrives BEFORE turn completion", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acne" });

    m.dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." });
    expect(m.state.pending).toHaveLength(0); // not durable until the turn is over

    const effects = m.dispatch({ type: "turnCompleted", speaker: "user" });
    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("I work at Acme.");
    expect(effects.some((e) => e.type === "startDurableExtraction")).toBe(true);
  });

  it("finalizes when the final transcription arrives AFTER turn completion", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acne" });

    const completed = m.dispatch({ type: "turnCompleted", speaker: "user" });
    expect(m.state.pending).toHaveLength(0); // waits for authoritative text
    expect(completed.some((e) => e.type === "scheduleFinalizationDeadline")).toBe(true);

    m.dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." });
    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("I work at Acme.");
  });

  it("falls back to the interim text when no final transcription ever arrives", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });

    m.dispatch({ type: "finalizationDeadline", speaker: "user", turnId: "turn-1" });

    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("I work at Acme.");
  });

  it("does not create a phantom turn when the deadline fires after finalization", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." });

    m.dispatch({ type: "finalizationDeadline", speaker: "user", turnId: "turn-1" });

    expect(m.state.pending).toHaveLength(1);
  });

  it("records the finalized turn in canonical conversation history", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "hi there" });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "Hi there." });

    expect(m.state.conversation).toEqual([
      expect.objectContaining({ role: "user", text: "Hi there." }),
    ]);
  });
});

describe("generation identity", () => {
  it("rejects a late provisional result whose transcript version was superseded", () => {
    const m = machine({ provisionalExtraction: true });
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    const first = m.dispatch({
      type: "interimTranscript",
      speaker: "user",
      text: "I work at Acne",
    });
    const started = first.find((e) => e.type === "startProvisionalExtraction");
    expect(started).toBeDefined();
    const staleKey = started!.key;

    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme" });

    m.dispatch({
      type: "provisionalExtractionSettled",
      key: staleKey,
      preview: { turnId: staleKey.turnId, entityNames: ["Acne"], relationLabels: [] },
    });

    expect(m.state.preview).toBeNull();
    expect(m.state.staleRejections).toBe(1);
  });

  it("cancels the superseded provisional request as an optimization", () => {
    const m = machine({ provisionalExtraction: true });
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acne" });
    const second = m.dispatch({
      type: "interimTranscript",
      speaker: "user",
      text: "I work at Acme",
    });

    expect(second.some((e) => e.type === "cancelExtraction")).toBe(true);
  });

  it("an older durable extraction resolving late cannot change a different notebook", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    const key = m
      .dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." })
      .find((e) => e.type === "startDurableExtraction")!.key;

    // The user switched notebooks while the extractor was still running.
    m.dispatch({ type: "sessionStarted", sessionId: "s2", notebookId: "nb2" });
    m.dispatch({ type: "durableExtractionSucceeded", key, payload: payload("Acme") });

    expect(m.state.pending).toHaveLength(0);
    expect(m.state.staleRejections).toBe(1);
  });

  it("rejects a durable result whose transcript version no longer matches the turn", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    const key = m
      .dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." })
      .find((e) => e.type === "startDurableExtraction")!.key;

    m.dispatch({
      type: "durableExtractionSucceeded",
      key: { ...key, transcriptVersion: key.transcriptVersion - 1 },
      payload: payload("Acme"),
    });

    expect(m.state.pending[0].extraction).toBeNull();
    expect(m.state.staleRejections).toBe(1);
  });

  it("a reconnect to the same notebook does NOT discard finalized durable work", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "I work at Acme." });

    // The live socket dropped and reconnected. The turn is already finalized;
    // losing it here would strand a write the server may never receive.
    m.dispatch({ type: "sessionStarted", sessionId: "s2", notebookId: "nb1" });

    expect(m.state.pending).toHaveLength(1);
    expect(m.state.active.user).toBeNull();
  });

  it("keeps a provisional preview display-only — never pending, conversation, or graph", () => {
    const m = machine({ provisionalExtraction: true });
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    const started = m
      .dispatch({ type: "interimTranscript", speaker: "user", text: "I work at Acme" })
      .find((e) => e.type === "startProvisionalExtraction");

    const effects = m.dispatch({
      type: "provisionalExtractionSettled",
      key: started!.key,
      preview: { turnId: started!.key.turnId, entityNames: ["Acme"], relationLabels: [] },
    });

    expect(m.state.preview?.entityNames).toEqual(["Acme"]);
    expect(m.state.pending).toHaveLength(0);
    expect(m.state.conversation).toHaveLength(0);
    expect(effects.some((e) => e.type === "persistTurn" || e.type === "startCommit")).toBe(false);
  });
});

describe("interrupted assistant speech", () => {
  it("finalizes only the words actually heard", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({
      type: "interimTranscript",
      speaker: "assistant",
      text: "You mentioned Acme. Your sister Mia lives in Oslo.",
    });
    m.dispatch({ type: "playbackAdvanced", heardChars: 21 });

    m.dispatch({ type: "assistantInterrupted", heardChars: 21 });
    m.dispatch({ type: "turnCompleted", speaker: "assistant" });

    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("You mentioned Acme.");
    expect(m.state.pending[0].truncatedFromInterruption).toBe(true);
    expect(m.state.conversation[0].text).toBe("You mentioned Acme.");
  });

  it("flushes playback and never extracts unheard words", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({
      type: "interimTranscript",
      speaker: "assistant",
      text: "You mentioned Acme. Your sister Mia lives in Oslo.",
    });
    const effects = m.dispatch({ type: "assistantInterrupted", heardChars: 21 });
    m.dispatch({ type: "turnCompleted", speaker: "assistant" });

    expect(effects.some((e) => e.type === "flushPlayback")).toBe(true);
    const durable = m.state.pending.map((t) => t.transcript).join(" ");
    expect(durable).not.toContain("Mia");
    expect(durable).not.toContain("Oslo");
  });

  it("skips durable extraction entirely when the heard boundary is unknown", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({
      type: "interimTranscript",
      speaker: "assistant",
      text: "You mentioned Acme. Your sister Mia lives in Oslo.",
    });

    m.dispatch({ type: "assistantInterrupted", heardChars: null });
    m.dispatch({ type: "turnCompleted", speaker: "assistant" });

    expect(m.state.pending).toHaveLength(0);
    expect(m.state.conversation).toHaveLength(0);
  });

  it("a late final transcript cannot resurrect unheard text after an interruption", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "interimTranscript", speaker: "assistant", text: "You mentioned Acme." });
    m.dispatch({ type: "assistantInterrupted", heardChars: 19 });
    m.dispatch({ type: "turnCompleted", speaker: "assistant" });

    m.dispatch({
      type: "finalTranscript",
      speaker: "assistant",
      text: "You mentioned Acme. Your sister Mia lives in Oslo.",
    });

    expect(m.state.pending).toHaveLength(1);
    expect(m.state.pending[0].transcript).toBe("You mentioned Acme.");
  });
});

/** Drives a turn from speech to "extraction result stored, commit not yet made". */
function finalizedTurn(m: ReturnType<typeof machine>, text: string) {
  m.dispatch({ type: "interimTranscript", speaker: "user", text });
  m.dispatch({ type: "turnCompleted", speaker: "user" });
  return m.dispatch({ type: "finalTranscript", speaker: "user", text });
}

describe("durable turn processing", () => {
  it("checkpoints the final transcript before extraction runs", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    const effects = finalizedTurn(m, "I work at Acme.");

    const persist = effects.findIndex((e) => e.type === "persistTurn");
    const extract = effects.findIndex((e) => e.type === "startDurableExtraction");
    expect(persist).toBeGreaterThanOrEqual(0);
    expect(extract).toBeGreaterThan(persist);
    expect(m.state.pending[0].stage).toBe("finalRecorded");
  });

  it("stores the extraction result before attempting the commit", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    const key = finalizedTurn(m, "I work at Acme.").find(
      (e) => e.type === "startDurableExtraction",
    )!.key;

    const effects = m.dispatch({
      type: "durableExtractionSucceeded",
      key,
      payload: payload("Acme"),
    });

    // The durable contract is about ordering of persisted checkpoints, not the
    // intermediate in-memory value: the extraction result must be on disk
    // before any commit is attempted.
    const persist = effects.findIndex(
      (e) => e.type === "persistTurn" && e.turn.stage === "extracted",
    );
    const commit = effects.findIndex((e) => e.type === "startCommit");
    expect(persist).toBeGreaterThanOrEqual(0);
    expect(commit).toBeGreaterThan(persist);
    const checkpoint = effects[persist];
    expect(checkpoint.type === "persistTurn" && checkpoint.turn.extraction).toEqual(
      payload("Acme"),
    );
    expect(m.state.pending[0].extraction).toEqual(payload("Acme"));
  });

  it("a restart after extraction reuses the stored result instead of re-extracting", () => {
    const stored = {
      turnId: "turn-1",
      sessionId: "s1",
      notebookId: "nb1",
      speaker: "user" as const,
      transcript: "I work at Acme.",
      transcriptVersion: 2,
      transcriptHash: "abc",
      extractorVersion: "v1",
      generation: 1,
      commitRequestId: "req-1",
      stage: "extracted" as const,
      extraction: payload("Acme"),
      baseRevision: null,
      revision: null,
      finalizedAt: "2026-09-10T00:00:00.000Z",
      truncatedFromInterruption: false,
    };
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    const effects = m.dispatch({ type: "restored", turns: [stored] });

    expect(effects.some((e) => e.type === "startDurableExtraction")).toBe(false);
    expect(effects.some((e) => e.type === "startCommit")).toBe(true);
  });

  it("reuses one commit request identifier when the commit outcome is unknown", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    const key = finalizedTurn(m, "I work at Acme.").find(
      (e) => e.type === "startDurableExtraction",
    )!.key;
    const first = m
      .dispatch({ type: "durableExtractionSucceeded", key, payload: payload("Acme") })
      .find((e) => e.type === "startCommit")!;

    // Server committed, response lost.
    const retry = m
      .dispatch({ type: "commitUnknown", turnId: "turn-1" })
      .find((e) => e.type === "startCommit")!;

    expect(retry.commitRequestId).toBe(first.commitRequestId);
    expect(m.state.pending[0].stage).toBe("commitPending");
  });

  it("removes the turn from the journal once committed", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    const key = finalizedTurn(m, "I work at Acme.").find(
      (e) => e.type === "startDurableExtraction",
    )!.key;
    m.dispatch({ type: "durableExtractionSucceeded", key, payload: payload("Acme") });

    const effects = m.dispatch({
      type: "commitCommitted",
      turnId: "turn-1",
      commitRequestId: "req-1",
      revision: 7,
    });

    expect(m.state.pending).toHaveLength(0);
    expect(m.state.revision).toBe(7);
    expect(effects.some((e) => e.type === "forgetTurn")).toBe(true);
  });

  it("replays multiple pending turns in order after a revision conflict, keeping their request ids", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });

    const k1 = finalizedTurn(m, "I work at Acme.").find(
      (e) => e.type === "startDurableExtraction",
    )!.key;
    m.dispatch({ type: "durableExtractionSucceeded", key: k1, payload: payload("Acme") });
    // Turn 2 finalizes while turn 1's commit is still in flight. Its own
    // durable work waits: turns are processed strictly in order.
    const second = finalizedTurn(m, "My manager is Sarah.");
    expect(second.some((e) => e.type === "startDurableExtraction")).toBe(false);

    const ids = m.state.pending.map((t) => t.commitRequestId);
    expect(m.state.pending.map((t) => t.transcript)).toEqual([
      "I work at Acme.",
      "My manager is Sarah.",
    ]);

    const conflict = m.dispatch({ type: "commitConflict", turnId: "turn-1", currentRevision: 12 });
    expect(conflict.some((e) => e.type === "reloadSnapshot")).toBe(true);
    expect(m.state.revision).toBe(12);

    const resumed = m.dispatch({ type: "snapshotReloaded", revision: 12 });
    const retry = resumed.find((e) => e.type === "startCommit")!;

    expect(retry.turnId).toBe("turn-1");
    expect(m.state.pending.map((t) => t.commitRequestId)).toEqual(ids);
  });
});

describe("conversation chronology", () => {
  function started() {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    return m;
  }

  it("orders turns by when they were spoken, not when they finalized", () => {
    const m = started();
    // The user's authoritative final lands only after Lumen's reply finalized.
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I met Priya" });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    m.dispatch({ type: "interimTranscript", speaker: "assistant", text: "How lovely." });
    m.dispatch({ type: "finalTranscript", speaker: "assistant", text: "How lovely." });
    m.dispatch({ type: "turnCompleted", speaker: "assistant" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "I met Priya." });

    expect(m.state.conversation.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(m.state.conversation[0].text).toBe("I met Priya.");
  });

  it("records the utterance start on each conversation turn", () => {
    const m = started();
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "Hello" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "Hello." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });

    const [turn] = m.state.conversation;
    expect(Date.parse(turn.startedAt)).toBeLessThan(Date.parse(turn.createdAt));
  });

  it("exposes a still-finalizing utterance as in progress, in its slot", () => {
    const m = started();
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "I met Priya" });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    m.dispatch({ type: "interimTranscript", speaker: "assistant", text: "How" });

    expect(m.inProgress.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(m.inProgress[0].text).toBe("I met Priya");
    expect(m.state.conversation).toEqual([]);
  });

  it("an in-progress turn leaves once it is finalized", () => {
    const m = started();
    m.dispatch({ type: "interimTranscript", speaker: "user", text: "Hi" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "Hi." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });
    expect(m.inProgress).toEqual([]);
    expect(m.state.conversation).toEqual([expect.objectContaining({ text: "Hi." })]);
  });
});

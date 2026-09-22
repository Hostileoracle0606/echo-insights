import { describe, expect, it } from "vitest";

import { createTranscriptAssembler } from "./transcript-assembler";

describe("createTranscriptAssembler", () => {
  it("restores unfinished transcription without losing the user turn boundary", () => {
    const first = createTranscriptAssembler();
    first.userChunk("I work at ");
    const second = createTranscriptAssembler(JSON.parse(JSON.stringify(first.checkpoint())));
    expect(second.userFinal("Acme.")).toEqual([
      { type: "finalTranscript", speaker: "user", text: "I work at Acme." },
    ]);
    expect(second.assistantChunk("Tell me more.")).toEqual([
      { type: "turnCompleted", speaker: "user" },
      { type: "interimTranscript", speaker: "assistant", text: "Tell me more." },
    ]);
  });
  it("turns incremental chunks into ONE replaceable interim transcript", () => {
    const a = createTranscriptAssembler();

    const first = a.userChunk("I work at Acme.");
    const second = a.userChunk(" My manager is Sarah.");

    expect(first).toEqual([
      { type: "interimTranscript", speaker: "user", text: "I work at Acme." },
    ]);
    // The second chunk replaces, it does not queue a second durable turn.
    expect(second).toEqual([
      {
        type: "interimTranscript",
        speaker: "user",
        text: "I work at Acme. My manager is Sarah.",
      },
    ]);
  });

  it("lets a provider interim replacement overwrite the accumulated buffer", () => {
    const a = createTranscriptAssembler();
    a.userChunk("I work at Acne");

    const events = a.userInterim("I work at Acme");

    expect(events).toEqual([
      { type: "interimTranscript", speaker: "user", text: "I work at Acme" },
    ]);
    // And a following chunk extends the corrected text, not the old one.
    expect(a.userChunk(".")).toEqual([
      { type: "interimTranscript", speaker: "user", text: "I work at Acme." },
    ]);
  });

  it("emits the whole accumulated turn when the transcription is marked finished", () => {
    const a = createTranscriptAssembler();
    a.userChunk("I work at ");

    expect(a.userFinal("Acme.")).toEqual([
      { type: "finalTranscript", speaker: "user", text: "I work at Acme." },
    ]);
  });

  it("closes the user turn when the assistant starts answering", () => {
    const a = createTranscriptAssembler();
    a.userChunk("Who is my manager?");

    const events = a.assistantChunk("You said Sarah");

    expect(events).toEqual([
      { type: "turnCompleted", speaker: "user", transcriptGeneration: 1 },
      { type: "interimTranscript", speaker: "assistant", text: "You said Sarah" },
    ]);
    // Only once: a second assistant chunk must not re-close the user turn.
    expect(a.assistantChunk(" is your manager.")).toEqual([
      {
        type: "interimTranscript",
        speaker: "assistant",
        text: "You said Sarah is your manager.",
      },
    ]);
  });

  it("completes the assistant turn on turnComplete and starts clean", () => {
    const a = createTranscriptAssembler();
    a.userChunk("Hello");
    a.assistantChunk("Hi there.");

    expect(a.turnComplete()).toEqual([
      { type: "turnCompleted", speaker: "assistant", transcriptGeneration: 2 },
    ]);
    // Buffers reset: the next turn starts from empty, not from "Hi there."
    expect(a.assistantChunk("Next answer.")).toEqual([
      { type: "interimTranscript", speaker: "assistant", text: "Next answer." },
    ]);
  });

  it("still completes a user turn that the assistant never answered", () => {
    const a = createTranscriptAssembler();
    a.userChunk("Just thinking out loud.");

    expect(a.turnComplete()).toEqual([
      { type: "turnCompleted", speaker: "user", transcriptGeneration: 1 },
      { type: "turnCompleted", speaker: "assistant" },
    ]);
  });

  it("preserves a user prefix when its final arrives after turn completion", () => {
    const a = createTranscriptAssembler();
    a.userChunk("I work at ");

    expect(a.assistantChunk("Tell me more.")[0]).toEqual({
      type: "turnCompleted",
      speaker: "user",
      transcriptGeneration: 1,
    });
    expect(a.userFinal("Acme.")).toEqual([
      { type: "finalTranscript", speaker: "user", text: "I work at Acme." },
    ]);
  });

  it("preserves an assistant prefix when its final arrives after turnComplete", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("You work at ");

    expect(a.turnComplete()).toEqual([
      { type: "turnCompleted", speaker: "assistant", transcriptGeneration: 1 },
    ]);
    expect(a.assistantFinal("Acme.")).toEqual([
      { type: "finalTranscript", speaker: "assistant", text: "You work at Acme." },
    ]);
  });

  it("restores a parked prefix from a checkpoint", () => {
    const first = createTranscriptAssembler();
    first.assistantChunk("You work at ");
    first.turnComplete();

    const restored = createTranscriptAssembler(JSON.parse(JSON.stringify(first.checkpoint())));
    expect(restored.assistantFinal("Acme.")).toEqual([
      { type: "finalTranscript", speaker: "assistant", text: "You work at Acme." },
    ]);
  });

  it("discards a final that arrives after its fallback deadline", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("Fallback text.");
    const completed = a.turnComplete()[0];
    if (completed?.type !== "turnCompleted" || completed.transcriptGeneration === undefined) {
      throw new Error("expected a parked assistant transcript");
    }

    a.expirePending("assistant", completed.transcriptGeneration);
    expect(a.assistantFinal(" Late duplicate.")).toEqual([]);
    expect(a.assistantChunk("Next answer.")).toEqual([
      { type: "interimTranscript", speaker: "assistant", text: "Next answer." },
    ]);
  });

  it("does not let an expired turn consume the next active turn final", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("Old answer.");
    const completed = a.turnComplete()[0];
    if (completed?.type !== "turnCompleted" || completed.transcriptGeneration === undefined) {
      throw new Error("expected a parked assistant transcript");
    }
    a.assistantChunk("New answer");

    a.expirePending("assistant", completed.transcriptGeneration);
    expect(a.assistantFinal(" complete.")).toEqual([
      {
        type: "finalTranscript",
        speaker: "assistant",
        text: "New answer complete.",
      },
    ]);
  });

  it("passes the heard-character watermark through on interruption", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("You mentioned Acme. Your sister Mia lives in Oslo.");

    expect(a.interrupted(19)).toEqual([{ type: "assistantInterrupted", heardChars: 19 }]);
  });

  it("reports an unknown heard boundary as unknown rather than guessing", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("You mentioned Acme.");

    expect(a.interrupted(null)).toEqual([{ type: "assistantInterrupted", heardChars: null }]);
  });

  it("does not park interrupted assistant text for a late final", () => {
    const a = createTranscriptAssembler();
    a.assistantChunk("Text that may not have been heard.");
    a.interrupted(null);

    expect(a.turnComplete()).toEqual([{ type: "turnCompleted", speaker: "assistant" }]);
    expect(a.assistantFinal(" trailing text")).toEqual([]);
  });
});

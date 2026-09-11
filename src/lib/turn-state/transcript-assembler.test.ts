import { describe, expect, it } from "vitest";

import { createTranscriptAssembler } from "./transcript-assembler";

describe("createTranscriptAssembler", () => {
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
      { type: "turnCompleted", speaker: "user" },
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

    expect(a.turnComplete()).toEqual([{ type: "turnCompleted", speaker: "assistant" }]);
    // Buffers reset: the next turn starts from empty, not from "Hi there."
    expect(a.assistantChunk("Next answer.")).toEqual([
      { type: "interimTranscript", speaker: "assistant", text: "Next answer." },
    ]);
  });

  it("still completes a user turn that the assistant never answered", () => {
    const a = createTranscriptAssembler();
    a.userChunk("Just thinking out loud.");

    expect(a.turnComplete()).toEqual([
      { type: "turnCompleted", speaker: "user" },
      { type: "turnCompleted", speaker: "assistant" },
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
});

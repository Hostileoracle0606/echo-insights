import { describe, expect, it } from "vitest";

import { stripFillers } from "./filler-words";
import { createTurnMachine } from "./reducer";

function machine() {
  let turnSeq = 0;
  let reqSeq = 0;
  let clock = 0;
  return createTurnMachine({
    now: () => new Date(1_700_000_000_000 + clock++ * 1000).toISOString(),
    newTurnId: () => `turn-${++turnSeq}`,
    newRequestId: () => `req-${++reqSeq}`,
  });
}

// Same cases as test/filler_words_test.dart: both ports must agree.
describe("stripFillers", () => {
  it("drops hesitation sounds and the commas around them", () => {
    expect(stripFillers("Um, my savings goal is, uh, three fifty now.")).toBe(
      "My savings goal is three fifty now.",
    );
    expect(stripFillers("So umm I think, erm, Kyoto.")).toBe("So I think Kyoto.");
    expect(stripFillers("Hmm... maybe Maya? Mm, yes.")).toBe("Maybe Maya? Yes.");
    expect(stripFillers("UH I mean UHM, Dune")).toBe("I mean Dune");
  });

  it("keeps words that only look like fillers", () => {
    for (const text of [
      "I like Dune.",
      "My umbrella broke.",
      "Uh-huh, that is right.",
      "Well, it went fine.",
      "Oh no.",
    ]) {
      expect(stripFillers(text)).toBe(text);
    }
  });

  it("turns a turn of only fillers into nothing", () => {
    expect(stripFillers("Um.")).toBe("");
    expect(stripFillers("uh, um... hmm")).toBe("");
  });
});

describe("finalized user turns", () => {
  it("are saved and extracted without fillers", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({
      type: "finalTranscript",
      speaker: "user",
      text: "Um, Maya starts her, uh, new job Monday.",
    });
    m.dispatch({ type: "turnCompleted", speaker: "user" });

    expect(m.state.pending[0].transcript).toBe("Maya starts her new job Monday.");
  });

  it("are dropped when they hold only fillers", () => {
    const m = machine();
    m.dispatch({ type: "sessionStarted", sessionId: "s1", notebookId: "nb1" });
    m.dispatch({ type: "finalTranscript", speaker: "user", text: "Um..." });
    m.dispatch({ type: "turnCompleted", speaker: "user" });

    expect(m.state.pending).toHaveLength(0);
  });
});

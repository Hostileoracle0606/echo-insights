import { describe, expect, it } from "vitest";

import { buildUserMessage } from "@/lib/extract-graph";
import type { Entity, JournalState, Relation } from "@/lib/journal-types";
import { resetMemoryIndex, retrieveMemory } from "@/lib/journal-memory";

import { compileExtractionContext, estimateTokens } from "./extraction-context";

function entity(id: string, name: string, over: Partial<Entity> = {}): Entity {
  return {
    id,
    name,
    type: "person",
    metadata: {},
    mentions: 1,
    firstSeen: "2026-01-01T00:00:00.000Z",
    lastSeen: "2026-01-01T00:00:00.000Z",
    ...over,
  };
}

function relation(id: string, source: string, target: string, label: string): Relation {
  return {
    id,
    source,
    target,
    label,
    metadata: {},
    createdAt: "2026-01-01T00:00:00.000Z",
  };
}

function stateOf(entities: Entity[], relations: Relation[] = []): JournalState {
  return {
    entries: [],
    entities: Object.fromEntries(entities.map((e) => [e.id, e])),
    relations: Object.fromEntries(relations.map((r) => [r.id, r])),
    followUps: [],
  };
}

describe("estimateTokens", () => {
  it("grows with content and never reports zero for non-empty text", () => {
    expect(estimateTokens("")).toBe(0);
    expect(estimateTokens("hello")).toBeGreaterThan(0);
    expect(estimateTokens("hello world and then some more")).toBeGreaterThan(
      estimateTokens("hello"),
    );
  });
});

describe("compileExtractionContext", () => {
  it("includes an older, rarely-mentioned entity that semantic retrieval surfaces", async () => {
    resetMemoryIndex();
    // 40 loud, irrelevant entities that a "top N by mentions" rule would pick.
    const noise = Array.from({ length: 40 }, (_, i) =>
      entity(`noise-${i}`, `Loud Person ${i}`, {
        mentions: 100 + i,
        description: "Frequently discussed but unrelated to the new utterance.",
        lastSeen: "2026-09-01T00:00:00.000Z",
      }),
    );
    const old = entity("kintsugi", "Kintsugi", {
      type: "activity",
      mentions: 1,
      description: "The Japanese art of repairing pottery with gold lacquer.",
      firstSeen: "2026-01-02T00:00:00.000Z",
      lastSeen: "2026-01-02T00:00:00.000Z",
    });
    const state = stateOf([...noise, old]);

    const transcript = "I finally got back to my Kintsugi bowls this weekend.";
    const retrieval = await retrieveMemory(state, transcript, "nb-test");

    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      recentTurns: [],
      budget: 1200,
    });

    expect(ctx.existingEntities.map((e) => e.name)).toContain("Kintsugi");
  });

  it("always includes exact normalized-name matches", async () => {
    resetMemoryIndex();
    const state = stateOf([
      entity("sarah", "Sarah", { mentions: 1 }),
      ...Array.from({ length: 30 }, (_, i) => entity(`o-${i}`, `Other ${i}`, { mentions: 50 })),
    ]);
    const transcript = "Sarah moved to the Oslo office.";
    const retrieval = await retrieveMemory(state, transcript, "nb-exact");

    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      recentTurns: [],
      budget: 400,
    });

    expect(ctx.existingEntities.map((e) => e.name)).toContain("Sarah");
  });

  it("preserves durable relation identifiers so contradictions can supersede correctly", async () => {
    resetMemoryIndex();
    const a = entity("acme", "Acme", { type: "organization" });
    const b = entity("sarah", "Sarah");
    const state = stateOf([a, b], [relation("rel-works", "sarah", "acme", "works_at")]);
    const transcript = "Sarah does not work at Acme any more.";
    const retrieval = await retrieveMemory(state, transcript, "nb-rel");

    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      recentTurns: [],
      budget: 800,
    });

    expect(ctx.existingRelations.map((r) => r.id)).toContain("rel-works");
  });

  it("stays within the token budget for a large graph", async () => {
    resetMemoryIndex();
    const entities = Array.from({ length: 500 }, (_, i) =>
      entity(`e-${i}`, `Entity Number ${i}`, {
        mentions: (i % 17) + 1,
        description:
          "A deliberately long description that exists to consume prompt budget, repeated " +
          "so that a count-based limit would blow past any sane token ceiling. ".repeat(3),
      }),
    );
    const relations = Array.from({ length: 1000 }, (_, i) =>
      relation(`r-${i}`, `e-${i % 500}`, `e-${(i + 7) % 500}`, `related_to_in_some_long_way_${i}`),
    );
    const state = stateOf(entities, relations);
    const transcript = "Entity Number 3 introduced me to Entity Number 11 at the conference.";
    const retrieval = await retrieveMemory(state, transcript, "nb-large");

    const budget = 900;
    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      recentTurns: Array.from({ length: 16 }, (_, i) => ({
        role: i % 2 === 0 ? ("user" as const) : ("assistant" as const),
        text: `A fairly wordy previous conversation turn number ${i} with plenty of filler.`,
      })),
      budget,
    });

    expect(ctx.tokensUsed).toBeLessThanOrEqual(budget);
    // A real prompt is actually produced, not an empty one.
    expect(ctx.existingEntities.length).toBeGreaterThan(0);
    // And the rendered prompt itself honours the bound.
    const rendered = buildUserMessage({ text: transcript, context: ctx.clientContext });
    expect(estimateTokens(rendered)).toBeLessThanOrEqual(budget);
  });

  it("never drops the new utterance, even when the budget is tiny", async () => {
    resetMemoryIndex();
    const state = stateOf([entity("acme", "Acme", { type: "organization" })]);
    const transcript = "I work at Acme and my manager is Sarah.";
    const retrieval = await retrieveMemory(state, transcript, "nb-tiny");

    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      recentTurns: [{ role: "user", text: "some earlier turn" }],
      budget: 5,
    });

    expect(ctx.existingEntities).toHaveLength(0);
    expect(ctx.recentConversation).toHaveLength(0);
    const rendered = buildUserMessage({ text: transcript, context: ctx.clientContext });
    expect(rendered).toContain(transcript);
  });

  it("adds the follow-up being answered ahead of recent conversation", async () => {
    resetMemoryIndex();
    const state = stateOf([entity("mia", "Mia")]);
    const transcript = "She moved there in March.";
    const retrieval = await retrieveMemory(state, transcript, "nb-fu");

    const ctx = compileExtractionContext({
      transcript,
      state,
      retrieval,
      answeringFollowUp: {
        id: "fu-1",
        question: "Where does Mia live now?",
        reason: "thin entity",
        targetEntityIds: ["mia"],
        createdAt: "2026-01-01T00:00:00.000Z",
        answered: false,
      },
      recentTurns: Array.from({ length: 8 }, () => ({
        role: "user" as const,
        text: "padding turn with a reasonable number of words in it to consume budget",
      })),
      // Enough for the ~104-token prompt scaffold plus the follow-up, but not
      // for all eight padding turns — so the two compete for the same budget.
      budget: 180,
    });

    expect(ctx.clientContext.answeringFollowUp?.question).toBe("Where does Mia live now?");
    expect(ctx.recentConversation.length).toBeLessThan(8);
    expect(ctx.tokensUsed).toBeLessThanOrEqual(180);
  });
});

describe("grounding versus extraction", () => {
  it("marks previous turns as reference-only and extracts solely from the new utterance", () => {
    const rendered = buildUserMessage({
      text: "She is my manager.",
      context: {
        existingEntities: [{ name: "Acme", type: "organization" }],
        existingRelations: [],
        recentConversation: [
          { role: "user", text: "I work at Acme." },
          { role: "assistant", text: "Who do you report to there?" },
        ],
      },
    });

    expect(rendered).toContain("do NOT extract from these turns");
    // The prior turn is present for pronoun resolution...
    expect(rendered).toContain("I work at Acme.");
    // ...but the new-utterance section contains only the current transcript.
    const utterance = rendered.slice(rendered.indexOf("NEW UTTERANCE:"));
    expect(utterance).toContain("She is my manager.");
    expect(utterance).not.toContain("I work at Acme.");
  });
});

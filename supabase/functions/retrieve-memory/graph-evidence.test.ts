import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { DbClient } from "../_shared/db-client.ts";
import type { Entity, GraphState, Relation } from "../_shared/graphloop/types.ts";
import { graphEvidence } from "./graph-evidence.ts";

// Routed recall answers from the graph: the entities that match the question
// (select.ts) and the journal entries linked to them, never a free-text
// passage search. This mirrors staging, where "Where is Priya moving?" failed
// because newer entries that only named Priya crowded out the statement.

const at = (day: number) => `2026-11-${String(day).padStart(2, "0")}T05:00:00Z`;
const e = (id: string, name: string): Entity => ({
  id,
  name,
  type: "other",
  metadata: {},
  mentions: 1,
  firstSeen: at(1),
  lastSeen: at(1),
});
const r = (id: string, source: string, target: string, label: string): Relation => ({
  id,
  source,
  target,
  label,
  metadata: {},
  createdAt: "",
});
const graph: GraphState = {
  entities: Object.fromEntries(
    [e("priya", "Priya"), e("lisbon", "Lisbon"), e("samsung", "Samsung")].map((x) => [x.id, x]),
  ),
  relations: { r1: r("r1", "priya", "lisbon", "moving_to") },
  entries: [],
};

const mention = (entryId: string, day: number, excerpt: string) => ({
  entryId,
  notebookId: `nb-${entryId}`,
  notebookTitle: "t",
  createdAt: at(day),
  excerpt,
  turnId: null,
  spokenAt: null,
});
const moving = mention("move", 1, "My sister Priya is moving to Lisbon next month.");
const mentionsById: Record<string, unknown[]> = {
  priya: [
    mention("p5", 22, "Priya, why you constantly asking me about her?"),
    mention("p4", 21, "She is a software developer."),
    mention("p3", 20, "I'm happy for her."),
    moving,
  ],
  lisbon: [moving, mention("l2", 2, "What is the Belem tower in Lisbon?")],
  samsung: [mention("s1", 3, "I work on AI at Samsung.")],
};

function client(calls: string[] = []): DbClient {
  return {
    auth: { getUser: () => Promise.reject(new Error("unused")) },
    from: () => {
      throw new Error("unused");
    },
    rpc: (name, args) => {
      calls.push(`${name}:${args.p_entity_id}`);
      return Promise.resolve({
        data: { total: 9, mentions: mentionsById[args.p_entity_id as string] ?? [] },
        error: null,
      });
    },
  };
}
const signal = new AbortController().signal;

Deno.test("evidence is the entries linked to the matched entities, most connected first", async () => {
  const result = await graphEvidence(client(), graph, "Priya move", new Map([["priya", 0.9]]), signal);
  assertEquals(result.entityIds, ["priya", "lisbon"]);
  // Linked to both Priya and Lisbon: ranked above newer Priya-only entries.
  assertEquals(result.passages[0], {
    entryId: "move",
    notebookId: "nb-move",
    text: "My sister Priya is moving to Lisbon next month.",
    spokenAt: null,
    createdAt: at(1),
  });
  assertEquals(result.passages.some((p) => p.entryId === "s1"), false);
});

Deno.test("no matching entity means no evidence and no entry lookups", async () => {
  const calls: string[] = [];
  const result = await graphEvidence(client(calls), graph, "the weather", new Map(), signal);
  assertEquals(result, { entityIds: [], passages: [] });
  assertEquals(calls, []);
});

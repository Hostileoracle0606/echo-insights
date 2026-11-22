import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { MemoryFact } from "../_shared/memory-fact-contract.ts";
import { createHandler, type DbClient } from "./handler.ts";
import type { MemoryPassage } from "./memory-query-types.ts";
import { OPEN_RECALL_TEXT, runMemoryQuery } from "./memory-query.ts";

// Routed recall (v3): the router classifies the question; graph selection
// picks the entities; an exact question is answered from their stored facts
// by code (EC-06), with no model call after the router. Anything no fact
// answers gets the user's own words.

const passage: MemoryPassage = {
  entryId: "journal-1",
  notebookId: "old-book",
  text: "I raised my savings goal from 5k to 8k.",
  spokenAt: null,
  createdAt: "2026-11-20T12:00:00Z",
};

const goalFact = (id: string, value: number, statedAt: string): MemoryFact => ({
  id,
  entityId: "savings-goal",
  attribute: "amount",
  valueNum: value,
  valueText: null,
  unit: "USD",
  status: "confirmed",
  eventAt: null,
  statedAt,
  supersedesFactId: null,
  provenance: "extracted",
  sourceNotebookId: "old-book",
  sourceEntryId: "journal-1",
});

const graph = {
  entityCount: 1,
  relationCount: 0,
  entities: [{
    id: "savings-goal",
    name: "savings goal",
    type: "concept",
    description: null,
    mentions: 2,
    firstSeen: "2026-11-03T12:00:00Z",
    lastSeen: "2026-11-20T12:00:00Z",
    notebookCount: 1,
  }],
  relations: [],
};

const passthrough: DbClient = {
  auth: { getUser: () => Promise.reject(new Error("unused")) },
  from: () => {
    throw new Error("unused");
  },
  rpc: (_name, args) => Promise.resolve({ data: args.p_text, error: null }),
};

function setup({
  owned = true,
  hangs = false,
  facts = [goalFact("f1", 5000, "2026-11-03T10:00:00+00:00"), goalFact("f2", 8000, "2026-11-20T10:00:00+00:00")],
  timeScope = "previous" as const,
  forget = "",
} = {}) {
  const events: string[] = [];
  const logs: Record<string, unknown>[] = [];
  const client: DbClient = {
    auth: { getUser: () => Promise.resolve({ data: { user: { id: "u1" } }, error: null }) },
    from: () => ({
      select: () => ({
        eq: () => ({
          single: () => Promise.resolve({ data: owned ? { id: "book-1" } : null, error: null }),
        }),
      }),
    }),
    rpc: (name, args) => {
      events.push(name);
      const data = name === "get_user_graph"
        ? graph
        : name === "get_entity_mentions"
        ? {
          total: 1,
          mentions: [{
            entryId: passage.entryId,
            notebookId: passage.notebookId,
            notebookTitle: "t",
            createdAt: passage.createdAt,
            excerpt: passage.text,
            turnId: null,
            spokenAt: null,
          }],
        }
        : name === "get_entity_fact_history"
        ? facts
        : name === "redact_forgotten_text"
        ? (forget ? String(args.p_text).replaceAll(forget, "someone") : String(args.p_text).replaceAll("Dana", "someone"))
        : true;
      return Promise.resolve({ data, error: null });
    },
  };
  const handler = createHandler({
    userClient: () => client,
    adminClient: () => {
      throw new Error("Unexpected admin client");
    },
    embedder: () => {
      throw new Error("No embedder: name matches only");
    },
    log: (fields) => logs.push(fields),
    memoryQuery: {
      timeoutMs: hangs ? 25 : 500,
      route: (question) => {
        events.push("route");
        assertEquals(question.includes("Dana"), false, "the question is redacted before routing");
        if (hangs) return new Promise(() => {});
        return Promise.resolve({ operation: "recall", timeScope });
      },
    },
  });
  const call = (question = "What was my savings goal before, with Dana?") =>
    handler(
      new Request("http://local/retrieve-memory", {
        method: "POST",
        headers: { Authorization: "Bearer synthetic" },
        body: JSON.stringify({
          scope: "user",
          notebookId: "book-1",
          version: 3,
          query: "savings goal",
          question,
        }),
      }),
    );
  return { call, events, logs };
}

Deno.test("a version question is answered from stored facts, with no model call after the router", async () => {
  const { call, events, logs } = setup();
  const response = await call();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.verdict, {
    status: "supported",
    text: "Savings goal amount before that: 5000 USD (said 3 Nov 2026).",
    sourceIds: ["journal-1"],
  });
  assertEquals(events, [
    "bump_retrieve_rate",
    "redact_forgotten_text",
    "redact_forgotten_text",
    "route",
    "get_user_graph",
    "get_entity_mentions",
    "get_entity_fact_history",
    "redact_forgotten_text",
  ]);
  assertEquals(logs.at(-1)?.outcome, "fact_answer");
  assertEquals(JSON.stringify(logs).includes("savings goal amount"), false, "no content in telemetry");
});

Deno.test("an exact question no stored fact answers gets the user's own words", async () => {
  const { call, logs } = setup({ facts: [] });
  const body = await (await call()).json();
  assertEquals(body.verdict.status, "supported");
  assertEquals(body.verdict.text, OPEN_RECALL_TEXT);
  assertEquals(body.quotes.map((q: { entryId: string }) => q.entryId), ["journal-1"]);
  assertEquals(logs.at(-1)?.outcome, "fact_fallback_quotes");
});

Deno.test("a fact answer that redaction would change is never returned", async () => {
  // The answer is checked like any outgoing text: if it would name someone
  // forgotten (redaction changes it), it is dropped for the user's own words.
  const redacting: DbClient = {
    ...passthrough,
    rpc: (_name, args) =>
      Promise.resolve({ data: String(args.p_text).replace("Savings goal", "someone"), error: null }),
  };
  const result = await runMemoryQuery(
    { route: () => Promise.resolve({ operation: "recall", timeScope: "previous" }) },
    redacting,
    "What was my previous goal?",
    "goal",
    Date.now(),
    {
      evidence: () => Promise.resolve([passage]),
      facts: () =>
        Promise.resolve({
          entities: [{ id: "savings-goal", name: "savings goal" }],
          facts: [
            goalFact("f1", 5000, "2026-11-03T10:00:00+00:00"),
            goalFact("f2", 8000, "2026-11-20T10:00:00+00:00"),
          ],
        }),
    },
    () => {},
  );
  assertEquals(result.verdict.text, OPEN_RECALL_TEXT);
  assertEquals(JSON.stringify(result).includes("5000"), false);
});

Deno.test("an elapsed deadline answers insufficient", async () => {
  const body = await (await setup({ hangs: true }).call()).json();
  assertEquals(body.verdict.status, "insufficient_evidence");
  assertEquals(body.quotes, []);
});

Deno.test("the routed path never runs for an unowned notebook", async () => {
  const { call, events } = setup({ owned: false });
  assertEquals((await call()).status, 404);
  assertEquals(events, []);
});


Deno.test("no matching entity answers insufficient", async () => {
  const result = await runMemoryQuery(
    { route: () => Promise.resolve({ operation: "recall", timeScope: "previous" }) },
    passthrough,
    "What was my previous goal?",
    "goal",
    Date.now(),
    {
      evidence: () => Promise.resolve([]),
      facts: () => Promise.resolve({ entities: [], facts: [] }),
    },
    () => {},
  );
  assertEquals(result.verdict.status, "insufficient_evidence");
});

Deno.test("a conversation decision skips retrieval without implying a missing answer", async () => {
  const unused = () => {
    throw new Error("No evidence lookup expected");
  };
  const result = await runMemoryQuery(
    { route: () => Promise.resolve({ operation: "conversation", timeScope: "unspecified" }) },
    passthrough,
    "I'm glad to hear that.",
    "",
    Date.now(),
    { evidence: unused, facts: unused },
    () => {},
  );
  assertEquals(result.verdict.status, "conversation");
});

Deno.test("when the router declines, code routes the question and it is still answered", async () => {
  const logs: Record<string, unknown>[] = [];
  const result = await runMemoryQuery(
    { route: () => Promise.resolve(null) },
    passthrough,
    "What was my savings goal before?",
    "savings goal",
    Date.now(),
    {
      evidence: () => Promise.resolve([passage]),
      facts: () =>
        Promise.resolve({
          entities: [{ id: "savings-goal", name: "savings goal" }],
          facts: [
            goalFact("f1", 5000, "2026-11-03T10:00:00+00:00"),
            goalFact("f2", 8000, "2026-11-20T10:00:00+00:00"),
          ],
        }),
    },
    (fields) => logs.push(fields),
  );
  assertEquals(result.verdict.text, "Savings goal amount before that: 5000 USD (said 3 Nov 2026).");
  assertEquals(logs.at(-1)?.routeFallback, true);
});

Deno.test("when the router declines a remark, nothing is looked up", async () => {
  const unused = () => {
    throw new Error("No lookup expected");
  };
  const result = await runMemoryQuery(
    { route: () => Promise.resolve(null) },
    passthrough,
    "Ask me something interesting.",
    "",
    Date.now(),
    { evidence: unused, facts: unused },
    () => {},
  );
  assertEquals(result.verdict.status, "conversation");
});

// Open recall ("What did I say about Priya?") has no value to compute, version
// to pick or event to confirm: the graph's linked entries go back as the
// user's own words, and no facts are read.
Deno.test("open recall answers from the linked entries", async () => {
  const logs: Record<string, unknown>[] = [];
  const entry = (entryId: string, text: string): MemoryPassage => ({
    ...passage,
    entryId,
    notebookId: `nb-${entryId}`,
    text,
  });
  const linked = [
    entry("move", "My sister Priya is moving to Lisbon next month."),
    entry("work", "No, I think she's moving there mostly for work."),
    entry("dev", "She is a software developer."),
    entry("happy", "I'm happy for her."),
  ];
  const result = await runMemoryQuery(
    { route: () => Promise.resolve({ operation: "recall", timeScope: "unspecified" }) },
    passthrough,
    "What did I say about Priya?",
    "Priya",
    Date.now(),
    {
      evidence: () => Promise.resolve(linked),
      facts: () => {
        throw new Error("open recall reads no facts");
      },
    },
    (fields) => logs.push(fields),
  );
  assertEquals(result.verdict.status, "supported");
  assertEquals(result.verdict.sourceIds, ["move", "work", "dev"]);
  assertEquals(result.quotes.map((q) => q.text), [
    "My sister Priya is moving to Lisbon next month.",
    "No, I think she's moving there mostly for work.",
    "She is a software developer.",
  ]);
  assertEquals(logs[0].outcome, "open_recall");
});

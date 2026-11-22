import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createEvidenceResolver } from "./evidence.ts";
import { createHandler, type DbClient } from "./handler.ts";
import type { MemoryPassage } from "./memory-query-types.ts";
import { runMemoryQuery } from "./memory-query.ts";

const passage: MemoryPassage = {
  entryId: "journal-1",
  notebookId: "old-book",
  text: "My earlier goal was level 100.",
  spokenAt: null,
  createdAt: "2026-10-10T12:00:00Z",
};

// The user's graph: Dana's goal entity, linked to one journal entry.
const graph = {
  entityCount: 1,
  relationCount: 0,
  entities: [{
    id: "goal",
    name: "goal",
    type: "concept",
    description: null,
    mentions: 1,
    firstSeen: "2026-10-10T12:00:00Z",
    lastSeen: "2026-10-10T12:00:00Z",
    notebookCount: 1,
  }],
  relations: [],
};

function setup(
  { owned = true, changed = false, hangs = false, plan = false } = {},
) {
  const events: string[] = [];
  const logs: unknown[] = [];
  let mentionReads = 0;
  const client: DbClient = {
    auth: {
      getUser: () =>
        Promise.resolve({ data: { user: { id: "u1" } }, error: null }),
    },
    from: () => ({
      select: () => ({
        eq: () => ({
          single: () =>
            Promise.resolve({
              data: owned ? { id: "book-1" } : null,
              error: null,
            }),
        }),
      }),
    }),
    rpc: (name, args) => {
      events.push(name);
      if (name === "get_user_graph") return Promise.resolve({ data: graph, error: null });
      if (name === "get_entity_mentions") {
        // The second read is the recheck before answering.
        const text = changed && mentionReads++ > 0 ? "Edited" : passage.text;
        if (!changed) mentionReads++;
        return Promise.resolve({
          data: {
            total: 1,
            mentions: [{
              entryId: passage.entryId,
              notebookId: passage.notebookId,
              notebookTitle: "t",
              createdAt: passage.createdAt,
              excerpt: text,
              turnId: null,
              spokenAt: null,
            }],
          },
          error: null,
        });
      }
      return Promise.resolve({
        data: name === "redact_forgotten_text"
          ? String(args.p_text).replaceAll("Dana", "someone")
          : true,
        error: null,
      });
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
        assertEquals(question, "What was my previous goal with someone?");
        if (hangs) return new Promise(() => {});
        return Promise.resolve({ operation: "recall", timeScope: "previous" });
      },
      resolve: (_question, route, passages) => {
        events.push("resolve");
        assertEquals(route.timeScope, "previous");
        assertEquals(passages, [passage]);
        return Promise.resolve({
          status: plan ? "clarification" : "supported",
          text: plan
            ? "The available entry describes a plan."
            : "Your previous goal was 100.",
          sourceIds: [passage.entryId],
        });
      },
    },
  });
  const call = () =>
    handler(
      new Request("http://local/retrieve-memory", {
        method: "POST",
        headers: { Authorization: "Bearer synthetic" },
        body: JSON.stringify({
          scope: "user",
          notebookId: "book-1",
          version: 3,
          query: "Dana goal",
          question: "What was my previous goal with Dana?",
        }),
      }),
    );
  return { call, events, logs };
}

Deno.test("full question is redacted and routed after access, with evidence rechecked", async () => {
  const { call, events, logs } = setup();
  const response = await call();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.version, 3);
  assertEquals(body.verdict, {
    status: "supported",
    text: "Your previous goal was 100.",
    sourceIds: ["journal-1"],
  });
  assertEquals(body.quotes.map((q: { entryId: string }) => q.entryId), [
    "journal-1",
  ]);
  // Evidence comes from the graph: the matching entity's linked entries,
  // read again before answering.
  assertEquals(events, [
    "bump_retrieve_rate",
    "redact_forgotten_text",
    "redact_forgotten_text",
    "route",
    "get_user_graph",
    "get_entity_mentions",
    "resolve",
    "redact_forgotten_text",
    "get_entity_mentions",
  ]);
  assertEquals(JSON.stringify(logs).includes("previous goal"), false);
});

Deno.test("edited source or elapsed deadline cannot produce a supported result", async () => {
  for (
    const condition of [{ changed: true }, { hangs: true }, {
      changed: true,
      plan: true,
    }]
  ) {
    const response = await setup(condition).call();
    const body = await response.json();
    assertEquals(body.version, 3);
    assertEquals(body.verdict.status, "insufficient_evidence");
    assertEquals(body.quotes, []);
  }
});

Deno.test("the routed path never runs for an unowned notebook", async () => {
  const { call, events } = setup({ owned: false });
  assertEquals((await call()).status, 404);
  assertEquals(events, []);
});

Deno.test("no matching entity answers insufficient without calling the resolver", async () => {
  const unused = () => {
    throw new Error("No resolver call expected");
  };
  const result = await runMemoryQuery(
    {
      route: () =>
        Promise.resolve({ operation: "recall", timeScope: "previous" }),
      resolve: unused,
    },
    {
      auth: { getUser: unused },
      from: unused,
      rpc: (_name, args) => Promise.resolve({ data: args.p_text, error: null }),
    },
    "What was my previous goal?",
    "goal",
    Date.now(),
    { evidence: () => Promise.resolve([]), reread: unused },
    () => {},
  );
  assertEquals(result.verdict.status, "insufficient_evidence");
});

Deno.test("a conversation decision skips retrieval without implying a missing answer", async () => {
  const unused = () => {
    throw new Error("No evidence lookup expected");
  };
  const result = await runMemoryQuery(
    {
      route: () =>
        Promise.resolve({
          operation: "conversation",
          timeScope: "unspecified",
        }),
      resolve: unused,
    },
    {
      auth: { getUser: unused },
      from: unused,
      rpc: (_name, args) => Promise.resolve({ data: args.p_text, error: null }),
    },
    "I'm glad to hear that.",
    "",
    Date.now(),
    { evidence: unused, reread: unused },
    () => {},
  );
  assertEquals(result.verdict.status, "conversation");
});

Deno.test("provider throttling asks the user to retry without inferring the journal lacks evidence", async () => {
  const logs: Record<string, unknown>[] = [];
  const unused = () => {
    throw new Error("Unexpected second lookup");
  };
  const result = await runMemoryQuery(
    {
      route: () =>
        Promise.resolve({ operation: "recall", timeScope: "previous" }),
      resolve: createEvidenceResolver({
        getApiKey: () => "synthetic",
        fetch: () => Promise.resolve(new Response(null, { status: 429 })),
      }),
    },
    {
      auth: { getUser: unused },
      from: unused,
      rpc: (_name, args) => Promise.resolve({ data: args.p_text, error: null }),
    },
    "What was my previous goal?",
    "goal",
    Date.now(),
    { evidence: () => Promise.resolve([passage]), reread: unused },
    (fields) => logs.push(fields),
  );
  assertEquals(result.verdict.status, "clarification");
  assertEquals(
    result.verdict.text,
    "I couldn't check your journal just now. Could you ask again?",
  );
  assertEquals(logs[0].outcome, "evidence_unavailable");
  assertEquals(logs[0].providerStatus, 429);
});

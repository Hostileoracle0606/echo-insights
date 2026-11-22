import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "../_shared/embedder.ts";
import { createHandler, type DbClient } from "./handler.ts";

// When routed recall finds no passage directly, it falls back to the graph:
// entries that mention the entities matching the question. That fallback
// used the general ranking, which returns most of a small graph, so a
// question about the Lumen app could be answered from Samsung entries.
// It now uses the same selection as the live tool (select.ts).

const NOW = new Date().toISOString();
const ent = (id: string, name: string, type: string, description: string | null = null) => ({
  id,
  name,
  type,
  description,
  mentions: 2,
  firstSeen: NOW,
  lastSeen: NOW,
  notebookCount: 1,
});
const mention = (entryId: string, notebookId: string, excerpt: string) => ({
  entryId,
  notebookId,
  notebookTitle: `title of ${notebookId}`,
  notebookStartedAt: NOW,
  conversationMode: "just_talk",
  createdAt: NOW,
  excerpt,
  turnId: null,
  spokenAt: null,
});

const graph = {
  entityCount: 3,
  relationCount: 1,
  entities: [
    ent("lumen-app", "Lumen app", "project"),
    ent("launch-checklist", "launch checklist", "project"),
    // "project" only in the description: a keyword hit the old ranking seeded.
    ent("samsung", "Samsung", "organization", "where the enterprise AI project is"),
  ],
  relations: [{ id: "r1", source: "lumen-app", target: "launch-checklist", label: "has" }],
};
const mentions: Record<string, unknown[]> = {
  "lumen-app": [mention("l1", "nb-a", "Lumen should be out by mid December")],
  "launch-checklist": [mention("c1", "nb-a", "I finished the launch checklist")],
  samsung: [mention("s1", "nb-b", "It's mostly our own enterprise AI at Samsung")],
};

function client(): DbClient {
  return {
    auth: { getUser: () => Promise.resolve({ data: { user: { id: "u1" } }, error: null }) },
    from: () => ({
      select: () => ({
        eq: () => ({ single: () => Promise.resolve({ data: { id: "book-1" }, error: null }) }),
      }),
    }),
    rpc: (name, args) => {
      const data = name === "redact_forgotten_text"
        ? args.p_text
        : name === "get_user_graph"
        ? graph
        : name === "get_entity_mentions"
        ? { total: 1, mentions: mentions[args.p_entity_id as string] ?? [] }
        : name === "match_user_entity_embeddings"
        ? [
          { entity_id: "lumen-app", notebook_id: "nb-a", score: 0.86 },
          { entity_id: "samsung", notebook_id: "nb-b", score: 0.74 },
        ]
        : true;
      return Promise.resolve({ data, error: null });
    },
  };
}

Deno.test("routed recall's graph fallback reads only entries of close matches", async () => {
  const searchedSources: string[][] = [];
  const handler = createHandler({
    userClient: client,
    adminClient: client,
    embedder: () => new StubEmbedder(),
    log: () => {},
    memoryQuery: {
      timeoutMs: 500,
      route: () => Promise.resolve({ operation: "recall", timeScope: "current" }),
      search: (_client, _question, _hint, _signal, sourceIds) => {
        if (sourceIds) searchedSources.push([...sourceIds].sort());
        return Promise.resolve([]);
      },
      resolve: () => Promise.resolve({ status: "insufficient_evidence", text: "", sourceIds: [] }),
      reread: () => Promise.resolve([]),
    },
  });

  const response = await handler(
    new Request("http://local/retrieve-memory", {
      method: "POST",
      headers: { Authorization: "Bearer synthetic" },
      body: JSON.stringify({
        scope: "user",
        notebookId: "book-1",
        version: 3,
        query: "Lumen project",
        question: "Where were we with the project before?",
      }),
    }),
  );

  assertEquals(response.status, 200);
  assertEquals(searchedSources, [["c1", "l1"]]);
});

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "../_shared/embedder.ts";
import {
  isRetrieveMemoryResponseV1,
  isRetrieveMemoryResponseV2,
} from "../_shared/retrieve-memory-contract.ts";
import { createHandler, type DbClient, type RetrieveMemoryDeps } from "./handler.ts";
import { clip, selectQuotes } from "./quotes.ts";

const OPEN_NB = "nb-open";
const USER_ID = "user-1";

type Call = { client: "user" | "admin"; fn: string; args: Record<string, unknown> };
type RpcImpl = (args: Record<string, unknown>) => { data: unknown; error: unknown };

function fakeClient(
  client: "user" | "admin",
  calls: Call[],
  rpcs: Record<string, RpcImpl>,
): DbClient {
  return {
    auth: { getUser: () => Promise.resolve({ data: { user: { id: USER_ID } }, error: null }) },
    from: () => ({
      select: () => ({
        eq: (_col: string, id: string) => ({
          single: () => Promise.resolve({ data: { id }, error: null }),
        }),
      }),
    }),
    rpc: (fn, args) => {
      calls.push({ client, fn, args });
      const impl = rpcs[fn];
      if (!impl) return Promise.resolve({ data: null, error: { message: `no fake for ${fn}` } });
      return Promise.resolve(impl(args));
    },
  };
}

function harness(rpcs: Record<string, RpcImpl>, opts: { embedder?: () => StubEmbedder } = {}) {
  const calls: Call[] = [];
  const logs: Record<string, unknown>[] = [];
  const all: Record<string, RpcImpl> = { bump_retrieve_rate: () => ({ data: true, error: null }), ...rpcs };
  const deps: RetrieveMemoryDeps = {
    userClient: () => fakeClient("user", calls, all),
    adminClient: () => fakeClient("admin", calls, all),
    embedder: opts.embedder ?? (() => {
      throw new Error("no Supabase.ai locally");
    }),
    log: (fields) => logs.push(fields),
  };
  const handler = createHandler(deps);
  const call = async (body: unknown) => {
    const res = await handler(
      new Request("http://local/retrieve-memory", {
        method: "POST",
        headers: { Authorization: "Bearer user-jwt" },
        body: JSON.stringify(body),
      }),
    );
    return { status: res.status, body: await res.json() };
  };
  return { call, calls, logs };
}

const NOW = new Date().toISOString();
const ent = (id: string, name: string, type = "person", description?: string) => ({
  id, name, type, description: description ?? null, mentions: 2, firstSeen: NOW, lastSeen: NOW, notebookCount: 2,
});

// The user's merged graph (get_user_graph shape).
const userGraph = {
  entityCount: 3,
  relationCount: 1,
  entities: [
    ent("priya", "Priya", "person", "runs the CI rotation"),
    ent("ci-fix", "CI fix", "project"),
    ent("lisbon", "Lisbon", "place"),
  ],
  relations: [{ id: "r1", source: "priya", target: "ci-fix", label: "owns" }],
};

const mention = (entryId: string, notebookId: string, createdAt: string, excerpt: string) => ({
  entryId,
  notebookId,
  notebookTitle: `title of ${notebookId}`,
  notebookStartedAt: createdAt,
  conversationMode: "just_talk",
  createdAt,
  excerpt,
  turnId: null,
  spokenAt: null,
});

const mentionsById: Record<string, unknown[]> = {
  priya: [
    mention("e-open", OPEN_NB, "2026-10-23T09:00:00Z", "Priya is here today"),
    mention("e5", "nb-b", "2026-10-16T17:00:00Z", "Priya said the CI fix is next"),
    mention("e3", "nb-c", "2026-10-09T09:00:00Z", "I paired with Priya"),
    mention("e1", "nb-d", "2026-09-01T09:00:00Z", "Met Priya at the offsite"),
  ],
  "ci-fix": [
    mention("e5", "nb-b", "2026-10-16T17:00:00Z", "Priya said the CI fix is next"),
    mention("e4", "nb-c", "2026-10-12T09:00:00Z", "The CI fix keeps slipping"),
  ],
};

const userScopeRpcs: Record<string, RpcImpl> = {
  get_user_graph: () => ({ data: userGraph, error: null }),
  get_entity_mentions: (args) => ({
    data: { total: 9, mentions: mentionsById[args.p_entity_id as string] ?? [] },
    error: null,
  }),
};

// ── notebook scope (old clients) ─────────────────────────────

Deno.test("a request without scope returns v1 from the client graph, unchanged", async () => {
  const h = harness({});
  const res = await h.call({
    query: "atlas",
    notebookId: OPEN_NB,
    state: {
      entities: {
        atlas: { id: "atlas", name: "Atlas", type: "project", metadata: {}, mentions: 4, firstSeen: NOW, lastSeen: NOW },
        maya: { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 3, firstSeen: NOW, lastSeen: NOW },
      },
      relations: {
        r1: { id: "r1", source: "maya", target: "atlas", label: "works_on", metadata: {}, createdAt: NOW },
      },
      entries: [],
    },
  });

  assertEquals(res.status, 200);
  assert(isRetrieveMemoryResponseV1(res.body));
  assertEquals(Object.keys(res.body).sort(), ["context", "entityIds", "version"]);
  assertEquals(res.body.entityIds, ["atlas", "maya"]);
  assert(res.body.context.includes("Maya --works_on--> Atlas"));
  // Never touches the user-wide read model.
  assertEquals(h.calls.map((c) => c.fn), ["bump_retrieve_rate"]);
});

Deno.test("notebook scope keeps the 413 guard for oversized client graphs", async () => {
  const h = harness({});
  const entities = Object.fromEntries(
    Array.from({ length: 2001 }, (_, i) => [`e${i}`, { id: `e${i}` }]),
  );
  const res = await h.call({ query: "x y", notebookId: OPEN_NB, state: { entities } });
  assertEquals(res.status, 413);
});

Deno.test("an unknown scope is rejected", async () => {
  const h = harness({});
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "everything" });
  assertEquals(res.status, 400);
});

// ── user scope ───────────────────────────────────────────────

Deno.test("user scope ignores body.state and reads the user graph with the user's token", async () => {
  const h = harness(userScopeRpcs);
  const res = await h.call({
    query: "Priya and Ghost",
    notebookId: OPEN_NB,
    scope: "user",
    state: {
      entities: {
        ghost: { id: "ghost", name: "Ghost", type: "person", metadata: {}, mentions: 9, firstSeen: NOW, lastSeen: NOW },
      },
    },
  });

  assertEquals(res.status, 200);
  assert(isRetrieveMemoryResponseV2(res.body));
  assert(res.body.entityIds.includes("priya"));
  assert(!res.body.entityIds.includes("ghost"));
  assert(!res.body.context.includes("Ghost"));

  const graphCall = h.calls.find((c) => c.fn === "get_user_graph")!;
  assertEquals(graphCall.client, "user");
  assertEquals(graphCall.args, { p_types: null, p_limit: 2000 });
  // Still rate-limited on the open conversation.
  assertEquals(h.calls[0], { client: "user", fn: "bump_retrieve_rate", args: { p_notebook_id: OPEN_NB } });
  // Mentions are read as the user, for at most the top 3 entities.
  const mentionCalls = h.calls.filter((c) => c.fn === "get_entity_mentions");
  assert(mentionCalls.length >= 1 && mentionCalls.length <= 3);
  assert(mentionCalls.every((c) => c.client === "user" && c.args.p_limit === 5));
});

Deno.test("user scope seeds come from match_user_entity_embeddings as the service role", async () => {
  const h = harness({
    ...userScopeRpcs,
    match_user_entity_embeddings: () => ({
      data: [
        { entity_id: "lisbon", notebook_id: "nb-c", score: 0.81 },
        { entity_id: "ci-fix", notebook_id: "nb-b", score: 0.6 },
      ],
      error: null,
    }),
  }, { embedder: () => new StubEmbedder() });

  // No lexical overlap with any entity name or description.
  const res = await h.call({ query: "that trip abroad", notebookId: OPEN_NB, scope: "user" });

  assertEquals(res.status, 200);
  assertEquals(res.body.entityIds, ["lisbon"]);
  const match = h.calls.find((c) => c.fn === "match_user_entity_embeddings")!;
  assertEquals(match.client, "admin");
  assertEquals(match.args.p_user_id, USER_ID);
  assertEquals(match.args.p_model, "stub@1");
  assertEquals(match.args.p_limit, 12);
});

Deno.test("quotes exclude the open notebook, dedupe by entry, cap at 3, newest first", async () => {
  const h = harness(userScopeRpcs);
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });

  assertEquals(res.status, 200);
  assert(isRetrieveMemoryResponseV2(res.body));
  assertEquals(res.body.quotes.map((q) => q.entryId), ["e5", "e4", "e3"]);
  assert(res.body.quotes.every((q) => q.notebookId !== OPEN_NB));
  assertEquals(res.body.quotes[0], {
    entryId: "e5",
    notebookId: "nb-b",
    turnId: null,
    spokenAt: null,
    createdAt: "2026-10-16T17:00:00Z",
    notebookTitle: "title of nb-b",
    text: "Priya said the CI fix is next",
  });
  // Quotes never leak into the private context.
  assert(!res.body.context.includes("CI fix is next"));
});

Deno.test("a get_entity_mentions failure still returns context, with no quotes", async () => {
  const h = harness({
    ...userScopeRpcs,
    get_entity_mentions: () => ({ data: null, error: { message: "boom" } }),
  });
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });

  assertEquals(res.status, 200);
  assert(isRetrieveMemoryResponseV2(res.body));
  assert(res.body.context.includes("Priya"));
  assertEquals(res.body.quotes, []);
});

Deno.test("a user with no memory gets an empty v2 response", async () => {
  const h = harness({
    get_user_graph: () => ({ data: { entityCount: 0, relationCount: 0, entities: [], relations: [] }, error: null }),
  });
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });
  assertEquals(res.body, { version: 2, context: "", entityIds: [], quotes: [] });
});

Deno.test("a failed user-graph read is a 500, not someone else's memory", async () => {
  const h = harness({ get_user_graph: () => ({ data: null, error: { message: "down" } }) });
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });
  assertEquals(res.status, 500);
  assertEquals(h.logs.at(-1)?.error, "user_graph_failed");
});

Deno.test("user scope is rate-limited on the open notebook", async () => {
  const h = harness({ ...userScopeRpcs, bump_retrieve_rate: () => ({ data: false, error: null }) });
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });
  assertEquals(res.status, 429);
  assert(!h.calls.some((c) => c.fn === "get_user_graph"));
});

Deno.test("telemetry carries scope and quoteCount, never the query, context or quote text", async () => {
  const h = harness(userScopeRpcs);
  const res = await h.call({ query: "Priya", notebookId: OPEN_NB, scope: "user" });
  const logged = JSON.stringify(h.logs);

  const ok = h.logs.find((l) => l.ok === true)!;
  assertEquals(ok.scope, "user");
  assertEquals(ok.quoteCount, 3);
  assert(!logged.includes("Priya"), "query / context / quote text must not be logged");
  for (const q of res.body.quotes) assert(!logged.includes(q.text));
});

// ── quote selection (pure) ───────────────────────────────────

Deno.test("selectQuotes skips malformed mentions and empty excerpts", () => {
  const quotes = selectQuotes(
    [[{ entryId: 4 }, mention("e1", "nb-b", "2026-10-01T00:00:00Z", "   "), mention("e2", "nb-b", "2026-10-02T00:00:00Z", " ok ")]],
    OPEN_NB,
  );
  assertEquals(quotes.map((q) => [q.entryId, q.text]), [["e2", "ok"]]);
});

Deno.test("clip caps at 280 UTF-16 units without splitting an emoji", () => {
  assertEquals(clip("x".repeat(300)).length, 280);
  const emojiAtEdge = "x".repeat(279) + "😀" + "tail";
  const clipped = clip(emojiAtEdge);
  assertEquals(clipped, "x".repeat(279));
  assert(clipped.length <= 280);
});

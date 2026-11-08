// Cross-feature scenario tests for retrieve-memory: what the handler returns
// after Forget a person (LM-49) and after auto-forget (LM-51).
//
// LIMITATION, stated plainly: the handler reads memory through database
// functions (get_user_graph, get_entity_mentions, match_user_entity_embeddings)
// that this suite can only fake. So the fakes below return what the real
// functions returned in supabase/tests/database/memory_recall_scenarios_test.sql
// at the same point of the same story (recorded from a local database run of
// that scenario), and the assertions are about the HANDLER: what it ranks,
// what it passes through and what it drops, given those inputs. Whether the
// database produces the right rows is that pgTAP file's job.
//
// The story (user U1, the same names as the pgTAP file):
//   S1  Priya Raman (sister, marathon) and Halvorsen Group (employer)
//   S2  Priya Raman's fracture; Priya Nair (a colleague); a Lisbon trip
//   auto-forget (7 days) sweeps S1's transcript; the graph, cards, brief stay
//   remove "work"; forget Priya Raman; S4 mentions her again
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "../_shared/embedder.ts";
import { isRetrieveMemoryResponseV2 } from "../_shared/retrieve-memory-contract.ts";
import { createHandler, type DbClient, type RetrieveMemoryDeps } from "./handler.ts";

const OPEN_NB = "a1000000-0000-0000-0000-000000000003"; // S3, the session asking
const USER_ID = "a0000000-0000-0000-0000-000000000001";

type Call = { client: "user" | "admin"; fn: string; args: Record<string, unknown> };
type RpcImpl = (args: Record<string, unknown>) => { data: unknown; error: unknown };

function fakeClient(client: "user" | "admin", calls: Call[], rpcs: Record<string, RpcImpl>): DbClient {
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

function harness(rpcs: Record<string, RpcImpl>) {
  const calls: Call[] = [];
  const all: Record<string, RpcImpl> = {
    bump_retrieve_rate: () => ({ data: true, error: null }),
    ...rpcs,
  };
  const deps: RetrieveMemoryDeps = {
    userClient: () => fakeClient("user", calls, all),
    adminClient: () => fakeClient("admin", calls, all),
    // StubEmbedder: the vector itself is irrelevant, the fake match ignores it.
    embedder: () => new StubEmbedder(),
    log: () => {},
  };
  const handler = createHandler(deps);
  const call = async (query: string) => {
    const res = await handler(
      new Request("http://local/retrieve-memory", {
        method: "POST",
        headers: { Authorization: "Bearer user-jwt" },
        body: JSON.stringify({ query, notebookId: OPEN_NB, scope: "user" }),
      }),
    );
    return { status: res.status, body: await res.json() };
  };
  return { call, calls };
}

// ── recorded database output ────────────────────────────────────────────────
const e = (
  id: string,
  name: string,
  type: string,
  description: string,
  mentions: number,
  notebookCount: number,
) => ({
  id,
  name,
  type,
  description,
  mentions,
  notebookCount,
  firstSeen: "2026-11-01T10:00:00+00:00",
  lastSeen: "2026-11-03T10:00:00+00:00",
});

/** get_user_graph() after auto-forget: S1's transcript is gone, the graph is whole. */
const GRAPH_AFTER_AUTOFORGET = {
  entityCount: 6,
  relationCount: 4,
  entities: [
    e("halvorsen-group", "Halvorsen Group", "organization", "Where I work; deadlines every week", 2, 2),
    e("priya-raman", "Priya Raman", "person", "My sister. Stress fracture, may skip the marathon", 2, 2),
    e("work", "work", "concept", "my job", 2, 1),
    e("lisbon-trip", "Lisbon trip", "event", "A trip Priya Nair is planning", 1, 1),
    e("priya-nair", "Priya Nair", "person", "Colleague at Halvorsen Group", 1, 1),
    e("city-marathon", "City Marathon", "event", "Priya Raman's first marathon", 1, 1),
  ],
  relations: [
    { id: "priya-nair__planning__lisbon-trip", label: "planning", source: "priya-nair", target: "lisbon-trip" },
    { id: "priya-nair__works_at__halvorsen-group", label: "works_at", source: "priya-nair", target: "halvorsen-group" },
    { id: "priya-raman__training_for__city-marathon", label: "training_for", source: "priya-raman", target: "city-marathon" },
    { id: "work__at__halvorsen-group", label: "at", source: "work", target: "halvorsen-group" },
  ],
};

/** get_user_graph() after "work" was removed, Priya Raman forgotten, and S4 committed. */
const GRAPH_AFTER_FORGET = {
  entityCount: 5,
  relationCount: 3,
  entities: [
    e("halvorsen-group", "Halvorsen Group", "organization", "Where I work. someone visited. Work is better", 3, 3),
    e("work-project", "Work project", "concept", "Work stuff: back to work", 1, 1),
    e("lisbon-trip", "Lisbon trip", "event", "A trip Priya Nair is planning", 1, 1),
    e("priya-nair", "Priya Nair", "person", "Colleague at Halvorsen Group", 1, 1),
    e("city-marathon", "City Marathon", "event", "someone's first marathon", 1, 1),
  ],
  relations: [
    { id: "priya-nair__planning__lisbon-trip", label: "planning", source: "priya-nair", target: "lisbon-trip" },
    { id: "priya-nair__works_at__halvorsen-group", label: "works_at", source: "priya-nair", target: "halvorsen-group" },
    { id: "work-project__at__halvorsen-group", label: "at", source: "work-project", target: "halvorsen-group" },
  ],
};

const MENTION_S2 = {
  turnId: "s2-t1",
  entryId: "entry-s2",
  excerpt:
    "Priya Raman has a stress fracture and may skip the marathon. Priya Nair at Halvorsen Group is planning a Lisbon trip.",
  spokenAt: "2026-11-05T17:07:45+00:00",
  createdAt: "2026-11-05T17:07:45+00:00",
  notebookId: "a1000000-0000-0000-0000-000000000002",
  notebookTitle: "The fracture",
  conversationMode: "just_talk",
  notebookStartedAt: "2026-11-05T17:07:45+00:00",
};
const MENTION_S4 = {
  turnId: null,
  entryId: "entry-s4",
  excerpt: "Priya Raman called again. Work at Halvorsen Group is better; back to work.",
  spokenAt: null,
  createdAt: "2026-11-07T17:07:45+00:00",
  notebookId: "a1000000-0000-0000-0000-000000000004",
  notebookTitle: "Work and Halvorsen Group",
  conversationMode: "just_talk",
  notebookStartedAt: "2026-11-07T17:07:45+00:00",
};

/** get_entity_mentions after auto-forget: S1's entries are swept, S2's remain. */
const mentionsAfterAutoForget = (id: string) => {
  const onS2 = ["priya-raman", "halvorsen-group", "priya-nair", "lisbon-trip"].includes(id);
  return { total: onS2 ? 1 : 0, mentions: onS2 ? [MENTION_S2] : [] };
};
/** get_entity_mentions after forget + S4, as the database returned it. */
const mentionsAfterForget = (id: string) => {
  switch (id) {
    case "halvorsen-group":
      return { total: 2, mentions: [MENTION_S4, MENTION_S2] };
    case "priya-nair":
    case "lisbon-trip":
      return { total: 1, mentions: [MENTION_S2] };
    default:
      return { total: 0, mentions: [] }; // priya-raman: no entry carries her id any more
  }
};

const seeds = (...ids: string[]) =>
  ids.map((entity_id, i) => ({
    entity_id,
    notebook_id: "a1000000-0000-0000-0000-000000000001",
    score: 0.95 - i * 0.05,
  }));

const rpcsAfterAutoForget = (matches: unknown[] = []): Record<string, RpcImpl> => ({
  get_user_graph: () => ({ data: GRAPH_AFTER_AUTOFORGET, error: null }),
  get_entity_mentions: (a) => ({ data: mentionsAfterAutoForget(String(a.p_entity_id)), error: null }),
  match_user_entity_embeddings: () => ({ data: matches, error: null }),
});
const rpcsAfterForget = (matches: unknown[] = []): Record<string, RpcImpl> => ({
  get_user_graph: () => ({ data: GRAPH_AFTER_FORGET, error: null }),
  get_entity_mentions: (a) => ({ data: mentionsAfterForget(String(a.p_entity_id)), error: null }),
  match_user_entity_embeddings: () => ({ data: matches, error: null }),
});

const everything = (body: unknown) => JSON.stringify(body).toLowerCase();

// ── after auto-forget: surviving memory is still returned ───────────────────

Deno.test("after auto-forget, retrieval still returns the people and relations it keeps", async () => {
  const h = harness(rpcsAfterAutoForget());
  const res = await h.call("how is my sister Priya Raman");
  assertEquals(res.status, 200);
  assert(isRetrieveMemoryResponseV2(res.body));
  assert(res.body.entityIds.includes("priya-raman"));
  assert(res.body.context.includes("Priya Raman (person): My sister. Stress fracture, may skip the marathon"));
  assert(res.body.context.includes("Priya Raman --training_for--> City Marathon"));
});

Deno.test("after auto-forget, a semantic seed reaches memory that has no lexical overlap", async () => {
  const h = harness(rpcsAfterAutoForget(seeds("lisbon-trip", "priya-nair")));
  const res = await h.call("that holiday abroad");
  assertEquals(res.status, 200);
  assert(res.body.entityIds.includes("lisbon-trip"));
  assert(res.body.context.includes("Priya Nair --planning--> Lisbon trip"));
  const match = h.calls.find((c) => c.fn === "match_user_entity_embeddings")!;
  assertEquals(match.client, "admin", "only the embedding match runs as the service role");
  assertEquals(match.args.p_user_id, USER_ID);
});

Deno.test("after auto-forget, quotes come only from the transcript that was kept (S2), never from the swept one (S1)", async () => {
  const h = harness(rpcsAfterAutoForget());
  const res = await h.call("Priya Raman");
  assertEquals(res.body.quotes.map((q: { entryId: string }) => q.entryId), ["entry-s2"]);
  assert(res.body.quotes.every((q: { notebookId: string }) => q.notebookId !== "a1000000-0000-0000-0000-000000000001"));
  // Reading a kept entry back to Lumen before the forget is expected: she is not forgotten yet.
  assert(res.body.quotes[0].text.includes("Priya Raman"));
});

Deno.test("after auto-forget, an empty quote list is a normal answer, not a failure", async () => {
  const h = harness({
    ...rpcsAfterAutoForget(),
    get_entity_mentions: () => ({ data: { total: 0, mentions: [] }, error: null }),
  });
  const res = await h.call("Priya Raman");
  assertEquals(res.status, 200);
  assertEquals(res.body.quotes, []);
  assert(res.body.context.includes("Priya Raman"), "memory outlives the transcript");
});

// ── after Forget: she and her words are not returned ───────────────────────

Deno.test("after forget, no query returns the forgotten person in context or ids", async () => {
  for (const query of ["Priya Raman", "my sister", "how is Priya", "the marathon", "Raman", "stress fracture"]) {
    const h = harness(rpcsAfterForget());
    const res = await h.call(query);
    assertEquals(res.status, 200, query);
    assert(!res.body.entityIds.includes("priya-raman"), query);
    const context = String(res.body.context).toLowerCase();
    assert(!context.includes("priya raman"), `${query}: ${context}`);
    assert(!context.includes("raman"), `${query}: ${context}`);
  }
});

Deno.test("after forget, a stale embedding of the forgotten person cannot bring her back", async () => {
  // An embed-entities job that was already running when she was forgotten can
  // write her embedding after the forget; the orphan prune only runs every 30
  // minutes. The match then returns her id first.
  const h = harness(rpcsAfterForget(seeds("priya-raman", "city-marathon")));
  const res = await h.call("my sister who runs");
  assertEquals(res.status, 200);
  assert(!res.body.entityIds.includes("priya-raman"), "an id with no entity in the graph is ignored");
  assert(!String(res.body.context).toLowerCase().includes("raman"));
  assert(res.body.entityIds.includes("city-marathon"), "the real entity the same match found is still returned");
  assert(!h.calls.some((c) => c.fn === "get_entity_mentions" && c.args.p_entity_id === "priya-raman"),
    "and quotes are never looked up for her");
});

Deno.test("after forget, text that was redacted in the database stays redacted in the context", async () => {
  const h = harness(rpcsAfterForget());
  const res = await h.call("City Marathon");
  assert(res.body.context.includes("City Marathon (event): someone's first marathon"));
  const hal = await harness(rpcsAfterForget()).call("Halvorsen Group");
  assert(hal.body.context.includes("Where I work. someone visited. Work is better"));
});

Deno.test("after forget, a different person with the same first name is still returned, text intact", async () => {
  const h = harness(rpcsAfterForget());
  const res = await h.call("Priya Nair");
  assertEquals(res.status, 200);
  assert(res.body.entityIds.includes("priya-nair"));
  assert(res.body.context.includes("Priya Nair (person): Colleague at Halvorsen Group"));
  assert(res.body.context.includes("Priya Nair --works_at--> Halvorsen Group"));
  const trip = await harness(rpcsAfterForget()).call("Lisbon trip");
  assert(trip.body.context.includes("A trip Priya Nair is planning"), "text naming Priya Nair is not over-redacted");
});

Deno.test("after forget, a plain first name finds the other Priya and never the forgotten one", async () => {
  const h = harness(rpcsAfterForget());
  const res = await h.call("Priya");
  assert(res.body.entityIds.includes("priya-nair"));
  assert(!res.body.entityIds.includes("priya-raman"));
});

Deno.test("after forget, a removed concept is not returned but similarly named memory is", async () => {
  const h = harness(rpcsAfterForget());
  const res = await h.call("work");
  assert(!res.body.entityIds.includes("work"));
  assert(res.body.entityIds.includes("work-project"));
  assert(res.body.context.includes("Work stuff: back to work"), "the word work is not redacted");
});

Deno.test("after forget, memory that survives is still returned, with relations", async () => {
  const h = harness(rpcsAfterForget(seeds("halvorsen-group", "priya-nair")));
  const res = await h.call("my job");
  assert(res.body.entityIds.includes("halvorsen-group"));
  assert(res.body.context.includes("Work project --at--> Halvorsen Group"));
});

Deno.test("the context never carries journal text, only entities and relations", async () => {
  const h = harness(rpcsAfterForget());
  const res = await h.call("Halvorsen Group");
  assert(!res.body.context.includes("## Sources"));
  assert(!res.body.context.includes("called again"), "quotes stay out of the private context");
});

// ── the gap: transcript text is quoted back verbatim ───────────────────────
// The handler passes get_entity_mentions excerpts through (it holds no list of
// forgotten names and could not match them if it did). Forget leaves
// journal_entries.text alone (ruling R10), so the excerpt of an entry that
// names her still reaches the quotes of any entity that entry also mentions:
// here Halvorsen Group, whose entry carries her name. That is Lumen being given
// "Priya Raman called again" as something the user said. Found by the pgTAP
// scenario (BUG-2); the fix is in the database (redact the excerpt, or redact
// journal_entries on forget), then this test passes unchanged.
Deno.test({
  name: "after forget, retrieval quotes do not repeat the forgotten name",
  ignore: true, // BUG-2: get_entity_mentions returns journal_entries.text unredacted
  fn: async () => {
    const h = harness(rpcsAfterForget());
    const res = await h.call("Halvorsen Group");
    assertEquals(res.status, 200);
    assert(res.body.quotes.length > 0, "there are quotes to check");
    assert(!everything(res.body.quotes).includes("priya raman"), everything(res.body.quotes));
  },
});

Deno.test({
  name: "after forget, nothing in the whole response repeats the forgotten name",
  ignore: true, // BUG-2, same cause
  fn: async () => {
    for (const query of ["Halvorsen Group", "Lisbon trip", "work"]) {
      const res = await harness(rpcsAfterForget()).call(query);
      assert(!everything(res.body).includes("priya raman"), `${query}: ${everything(res.body)}`);
    }
  },
});

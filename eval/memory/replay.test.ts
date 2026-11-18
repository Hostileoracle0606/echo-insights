// Runs under vitest with eval/memory/vite.config.ts (the TS app modules need
// the repo's @ alias): npx vitest run --config eval/memory/vite.config.ts
import { describe, expect, it } from "vitest";
import { BudgetExhausted, createBudget, providerFetch } from "./budget.mjs";
import { replayScenario } from "./replay";

const SUPABASE = "http://127.0.0.1:55321";
const NOTEBOOK = "11111111-2222-4333-8444-555555555555";
const scenario = {
  id: "job-change-decided",
  category: "changing_facts",
  sessions: [
    { turns: ["I might leave Northwind, the commute is killing me."] },
    { turns: ["Talked it over with Priya Raman. I decided to stay at Northwind."] },
  ],
  actions: [{ after_session: 1, kind: "forget", name: "Northwind" }],
  probes: [{ ask: "x", expect_retrieved: ["Northwind"] }],
};

function fakeBackend() {
  const events: string[] = [];
  const expectedRevisions: number[] = [];
  let revision = 0;
  const entities: Record<string, unknown> = {};
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
  const realFetch = async (input: string | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    if (url.hostname === "generativelanguage.googleapis.com") {
      events.push("extract");
      return json({
        candidates: [{ content: { parts: [{ functionCall: { name: "extract_graph", args: {
          entities: [{ name: "Northwind", type: "organization", description: "Where the user works." }],
          relations: [], supersedes: [],
        } } }] } }],
      });
    }
    const path = url.pathname;
    if (path === "/auth/v1/user") return json({ id: "user-1" });
    if (path === "/rest/v1/notebooks" && init?.method === "POST") return json([{ id: NOTEBOOK, revision: 0 }], 201);
    if (path === "/rest/v1/notebooks") return json([{ id: NOTEBOOK }]);
    if (path === "/rest/v1/conversation_turns") {
      // As lib/services/transcript_store.dart saves: insert-only, owner from the column default.
      const prefer = new Headers(init?.headers).get("prefer");
      events.push(prefer === "resolution=ignore-duplicates" && !("user_id" in body) ? "turn" : `bad-turn:${prefer}`);
      return new Response(null, { status: 201 });
    }
    if (path === "/rest/v1/rpc/redact_forgotten_text") return json(body.p_text);
    if (path === "/rest/v1/rpc/get_notebook_snapshot") {
      return json({ notebookId: NOTEBOOK, revision, state: { entries: [], entities, relations: {}, followUps: [], askedQuestions: [] } });
    }
    if (path === "/rest/v1/rpc/commit_notebook") {
      events.push("commit");
      expectedRevisions.push(body.p_expected_revision);
      for (const e of body.p_change.entities) entities[e.id] = e;
      revision += 1;
      return json({ status: "committed", requestId: body.p_request_id, revision, ids: {} });
    }
    if (path === "/rest/v1/rpc/forget_entity") { events.push(`forget:${body.p_entity_id}`); return json({ forgotten: true }); }
    return json({ message: `unhandled ${path}` }, 404);
  };
  return { events, expectedRevisions, realFetch };
}

const env = { supabaseUrl: SUPABASE, anonKey: "anon", user: { id: "user-1", token: "user-token" }, geminiKey: "test-key" };

describe("replayScenario", () => {
  it("extracts and commits once per turn, in revision order, and forgets after session 1", async () => {
    const backend = fakeBackend();
    const fetchImpl = providerFetch({ realFetch: backend.realFetch, budget: createBudget(10),
      providerHosts: ["generativelanguage.googleapis.com"], supabaseUrl: SUPABASE });
    let snapshotted = 0;
    const result = await replayScenario({ scenario, env, fetchImpl,
      takeSnapshot: async () => { snapshotted += 1; return { version: 1 } as never; } });
    expect(backend.events.filter((e) => e === "extract")).toHaveLength(2);
    expect(backend.expectedRevisions).toEqual([0, 1]);
    expect(backend.events).toEqual(["turn", "extract", "commit", "forget:northwind", "turn", "extract", "commit"]);
    expect(snapshotted).toBe(1);
    expect(result.meta.providerCalls).toBe(2);
    expect(result.meta.actions).toEqual([{ after_session: 1, kind: "forget", name: "Northwind", entityId: "northwind", outcome: "applied" }]);
  });

  it("throws BudgetExhausted mid-scenario without taking a snapshot", async () => {
    const backend = fakeBackend();
    const fetchImpl = providerFetch({ realFetch: backend.realFetch, budget: createBudget(1),
      providerHosts: ["generativelanguage.googleapis.com"], supabaseUrl: SUPABASE });
    let snapshotted = 0;
    await expect(replayScenario({ scenario, env, fetchImpl,
      takeSnapshot: async () => { snapshotted += 1; return { version: 1 } as never; } }))
      .rejects.toBeInstanceOf(BudgetExhausted);
    expect(snapshotted).toBe(0);
    expect(backend.events.filter((e) => e === "extract")).toHaveLength(1);
  });
});

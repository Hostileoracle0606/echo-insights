// Runs under vite-node (it imports the app's TS turn pipeline). The .mjs
// wrapper beside it makes `node --test eval/recovery/*.test.mjs` run it.
import assert from "node:assert/strict";
import { test } from "node:test";

import { countDuplicates } from "./audit.mjs";
import fixtures from "./fixtures/patches.json";
import { FAULTS, judge, runFault, type ScenarioEnv } from "./scenarios";

type Entry = { id: string; text: string; createdAt: string; entityIds: string[]; relationIds: string[] };

/**
 * In-memory commit_notebook / get_notebook_snapshot / conversation_turns.
 * `idempotent: false` forgets its request ledger, so a replayed request
 * applies twice: the control proving the harness can see a duplicate.
 */
function fakeEnv({ idempotent = true } = {}) {
  const url = "http://127.0.0.1:59999";
  let revision = 0;
  const entries: Entry[] = [];
  const entities: Record<string, { id: string; name: string }> = {};
  const turns = new Map<string, string>();
  const ledger = new Map<string, unknown>();
  const commitRequestIds: string[] = [];
  const extractions = new Map<string, number>();

  const json = (value: unknown, status = 200) =>
    new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

  const realFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = new URL(String(input)).pathname;
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    if (path === "/rest/v1/rpc/commit_notebook") {
      commitRequestIds.push(body.p_request_id);
      if (idempotent && ledger.has(body.p_request_id)) return json(ledger.get(body.p_request_id));
      if (body.p_expected_revision !== revision) return json({ status: "conflict", currentRevision: revision });
      const change = body.p_change;
      revision += 1;
      const id = `entry-${entries.length + 1}`;
      entries.push({ id, text: change.entry.text, createdAt: new Date().toISOString(), entityIds: change.entry.entityIds, relationIds: [] });
      for (const e of change.entities) entities[e.id] = { id: e.id, name: e.name };
      const result = { status: "committed", requestId: body.p_request_id, revision, ids: { entryId: id } };
      ledger.set(body.p_request_id, result);
      return json(result);
    }
    if (path === "/rest/v1/rpc/get_notebook_snapshot") {
      return json({
        notebookId: body.p_notebook_id,
        revision,
        state: { entries, entities, relations: {}, followUps: [], askedQuestions: [] },
      });
    }
    if (path === "/rest/v1/conversation_turns") {
      const rows = Array.isArray(body) ? body : [body];
      for (const row of rows) if (!turns.has(row.turn_id)) turns.set(row.turn_id, row.text);
      return new Response(null, { status: 201 });
    }
    return json({ message: "not found" }, 404);
  }) as typeof fetch;

  const byText = Object.values(fixtures.turns);
  const env: ScenarioEnv = {
    supabaseUrl: url,
    anonKey: "anon",
    realFetch,
    newUser: async () => ({ userId: "user-1", token: "token-1", notebookId: "notebook-1" }),
    cleanupUser: async () => {},
    gateway: async (route, event) => {
      if (route !== "extractions") return { statusCode: 404, body: "{}" };
      const { text } = JSON.parse(event.body);
      // As the real Lambda's claim store: a turn already extracted is served
      // from the cache, so only the first request per turn reaches the model.
      if (!extractions.has(text)) extractions.set(text, 1);
      const turn = byText.find((t) => t.text === text);
      return { statusCode: 200, body: JSON.stringify({ patch: { supersedes: [], ...turn!.patch } }) };
    },
    audit: async () => {
      const counts = { journal_entries: entries.length, entities: Object.keys(entities).length, relations: 0, conversation_turns: turns.size, session_briefs: 0 };
      const duplicates = {
        journal_entries: countDuplicates(entries, (e: Entry) => e.text),
        entities: countDuplicates(Object.values(entities), (e: { name: string }) => e.name.toLowerCase()),
        relations: 0,
        conversation_turns: 0,
        session_briefs: 0,
      };
      return { counts, duplicates };
    },
    texts: async () => ({ journal: entries.map((e) => e.text), turns: [...turns.values()] }),
    providerCalls: () => ({ real: 0, stub: [...extractions.values()].reduce((a, b) => a + b, 0) }),
    extractCalls: (text) => extractions.get(text) ?? 0,
  };
  return { env, commitRequestIds };
}

const t2 = fixtures.turns.t2.text;

test("FAULTS lists the eight scenarios", () => {
  assert.deepEqual(FAULTS, [
    "extract_before", "extract_lost_ack", "commit_before", "commit_lost_ack",
    "kill_after_journal", "kill_after_extract", "concurrent_commit", "brief_lost_ack",
  ]);
});

test("commit_lost_ack: the retry reuses the request id and turn 2 lands once", async () => {
  const { env, commitRequestIds } = fakeEnv();
  const result = await runFault("commit_lost_ack", 1, env);
  assert.equal(result.triggered, true);
  // turn 1, turn 2 (lost ack), turn 2 retry, turn 3
  assert.equal(commitRequestIds.length, 4);
  assert.equal(commitRequestIds[1], commitRequestIds[2]);
  assert.equal(result.partial_turn, "recovered");
  assert.deepEqual(result.completed_turns_kept, { n: 2, of: 2 });
  assert.equal(Object.values(result.duplicates).reduce((a, b) => a + b, 0), 0);
  assert.equal(result.pass, true);
  assert.equal(result.provider_real_calls, 0);
});

test("control: a server that re-applies a replay is reported as duplicated", async () => {
  const { env } = fakeEnv({ idempotent: false });
  const result = await runFault("commit_lost_ack", 1, env);
  assert.equal(result.partial_turn, "duplicated");
  assert.equal(result.duplicates.journal_entries, 1);
  assert.equal(result.pass, false);
});

test("kill_after_journal: turn 2 is resumed from the journal and extracted once", async () => {
  // Odd seeds kill after the extractor answered, even seeds before it was reached.
  for (const seed of [1, 2]) {
    const { env } = fakeEnv();
    const result = await runFault("kill_after_journal", seed, env);
    assert.equal(result.triggered, true, `seed ${seed}`);
    assert.equal(result.resumed, 1, `seed ${seed}`);
    assert.equal(result.partial_turn, "recovered", `seed ${seed}`);
    assert.equal(env.extractCalls(t2), 1, `seed ${seed}`);
    assert.equal(result.pass, true, `seed ${seed}`);
  }
});

test("a fault that never fires is not_triggered, never a pass", async () => {
  const { env } = fakeEnv();
  const result = await runFault("commit_before", 1, env, { after: 99 });
  assert.equal(result.triggered, false);
  assert.equal(result.outcome, "not_triggered");
  assert.equal(result.pass, false);
});

// The pass rule is per fault: only extraction faults may leave turn 2 out of
// the graph. Everything else must finish it exactly once.
const clean = {
  triggered: true, kept: 2, of: 2, duplicateTotal: 0, partial: "recovered" as const,
  resumed: 0, turn2Extractions: 1, conflicts: 0, stubCalls: 3,
};

test("judge: extraction faults may leave turn 2 marked or dropped", () => {
  assert.equal(judge("extract_lost_ack", { ...clean, partial: "marked" }), "pass");
  assert.equal(judge("extract_before", { ...clean, partial: "dropped", turn2Extractions: 0 }), "pass");
});

test("judge: a kill whose restart did not resume turn 2 fails", () => {
  assert.equal(judge("kill_after_journal", { ...clean, resumed: 1 }), "pass");
  assert.equal(judge("kill_after_journal", { ...clean, partial: "marked", resumed: 0 }), "fail");
  assert.equal(judge("kill_after_extract", { ...clean, resumed: 0 }), "fail");
  assert.equal(judge("kill_after_journal", { ...clean, resumed: 1, turn2Extractions: 2 }), "fail");
});

test("judge: a commit fault must recover, not merely drop", () => {
  assert.equal(judge("commit_lost_ack", clean), "pass");
  assert.equal(judge("commit_lost_ack", { ...clean, partial: "dropped" }), "fail");
});

test("judge: a racing device that dropped its turn instead of rebasing fails", () => {
  assert.equal(judge("concurrent_commit", { ...clean, conflicts: 1 }), "pass");
  assert.equal(judge("concurrent_commit", { ...clean, conflicts: 1, partial: "dropped" }), "fail");
});

test("judge: a retried close must be answered unchanged, with no second brief", () => {
  const brief = { ...clean, kept: 3, of: 3, stubCalls: 5 };
  assert.equal(judge("brief_lost_ack", { ...brief, brief: { first: "lost", retry: "unchanged" } }), "pass");
  assert.equal(judge("brief_lost_ack", { ...brief, stubCalls: 7, brief: { first: "lost", retry: "ready" } }), "fail");
});

test("judge: untriggered is inconclusive; lost or duplicated rows fail", () => {
  assert.equal(judge("commit_before", { ...clean, triggered: false }), "not_triggered");
  assert.equal(judge("extract_before", { ...clean, partial: "marked", kept: 1 }), "fail");
  assert.equal(judge("extract_before", { ...clean, partial: "marked", duplicateTotal: 1 }), "fail");
});

// Sequential network hops inside the two AWS runtime handlers on a user's
// path: graph extraction (every user turn) and close-session (leaving a
// conversation). Every fake dependency waits a fixed time, so the elapsed time
// decomposes into "how many of each hop happen one after another".
//
// Not part of `npm test` (it only globs test/*.test.mjs). Run:
//   cd infra && node --test test/perf/server-hops.test.mjs
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createExtractGraphHandler } from "../../lambda/extract-graph/core.mjs";
import { createCloseSessionHandler } from "../../lambda/close-session/core.mjs";

const SUPABASE_MS = 40; // one PostgREST / RPC round trip
const MODEL_MS = 300; // stand-in for a Gemini generateContent call
const SECRET_MS = 25; // Secrets Manager GetSecretValue
const DYNAMO_MS = 10; // DynamoDB conditional write

const delay = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));
const ok = (body) => ({ ok: true, status: 200, json: async () => structuredClone(body) });

function recorder() {
  const t0 = performance.now();
  const events = [];
  return {
    events,
    async hop(kind, ms, value) {
      const start = performance.now() - t0;
      const result = await delay(ms, value);
      events.push({ kind, start, end: performance.now() - t0 });
      return result;
    },
  };
}

/** Counts how many hops of each kind ran without overlapping another of any kind. */
function summarize(name, total, events) {
  const byKind = {};
  for (const e of events) byKind[e.kind] = (byKind[e.kind] ?? 0) + 1;
  const sorted = [...events].sort((a, b) => a.start - b.start);
  let sequential = 0;
  let frontier = -1;
  for (const e of sorted) {
    if (e.start >= frontier - 1) sequential += 1;
    frontier = Math.max(frontier, e.end);
  }
  console.log(`PERF ${name} total=${total.toFixed(0)}ms sequentialSteps=${sequential} calls=${JSON.stringify(byKind)}`);
  console.log(`PERF ${name} order: ${sorted.map((e) => e.kind).join(" → ")}`);
}

test("extraction: hops per user turn", async () => {
  const notebookId = "8e03b8f4-4f20-4df3-8398-d854adc32b14";
  const rec = recorder();
  const handle = createExtractGraphHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "pk",
    getPermanentCredential: () => rec.hop("secret", SECRET_MS, "gemini-key"),
    acquireExtraction: () => rec.hop("dynamo", DYNAMO_MS, { status: "acquired" }),
    completeExtraction: ({ patch }) => rec.hop("dynamo", DYNAMO_MS, { status: "completed", patch }),
    newOwnerToken: () => "owner",
    now: () => Date.now(),
    sleep: async () => {},
    fetchImpl: async (url) => {
      if (String(url).includes("generativelanguage.googleapis.com")) {
        return rec.hop("gemini", MODEL_MS, ok({
          candidates: [{ content: { parts: [{ functionCall: {
            name: "extract_graph",
            args: { entities: [{ name: "Maya", type: "person" }], relations: [], supersedes: [] },
          } }] } }],
        }));
      }
      return rec.hop("supabase", SUPABASE_MS, ok([{ id: notebookId }]));
    },
  });
  const t0 = performance.now();
  const response = await handle({
    headers: { authorization: "Bearer user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-1" } } },
    body: JSON.stringify({
      turnId: "t1",
      extractorVersion: "gemini/extract_graph/v2",
      text: "Maya and I discussed Project Atlas today.",
      mode: "granular",
      context: { entities: [], relations: [], recentConversation: [], answeringFollowUp: null },
    }),
  });
  const total = performance.now() - t0;
  assert.equal(response.statusCode, 200);
  summarize("extract_handler", total, rec.events);
});

test("close-session: hops when leaving a Just talk conversation", async () => {
  const fixture = JSON.parse(
    await readFile(new URL("../fixtures/close-session.just-talk.json", import.meta.url), "utf8"),
  );
  const notebookId = fixture.notebook.id;
  const rec = recorder();
  let stored = null;
  const handle = createCloseSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "pk",
    getPermanentCredential: () => rec.hop("secret", SECRET_MS, "gemini-key"),
    now: () => Date.parse("2026-10-23T21:05:00.000Z"),
    sleep: async () => {},
    log: () => {},
    fetchImpl: async (input, init = {}) => {
      const url = new URL(String(input));
      const body = init.body ? JSON.parse(init.body) : null;
      if (url.hostname === "generativelanguage.googleapis.com") {
        return rec.hop("gemini", MODEL_MS, ok({
          candidates: [{ content: { parts: [{ functionCall: { name: "write_session_card", args: fixture.modelArgs } }] } }],
        }));
      }
      const path = url.pathname;
      const answer = {
        "/rest/v1/notebooks": [fixture.notebook],
        "/rest/v1/session_cards": stored ? [stored] : [],
        "/rest/v1/rpc/get_notebook_snapshot": fixture.snapshot,
        "/rest/v1/conversation_turns": [...fixture.turns].sort((a, b) => b.spoken_at.localeCompare(a.spoken_at)),
        "/rest/v1/user_entities": fixture.userEntities,
      }[path];
      if (path === "/rest/v1/rpc/save_session_card") {
        stored = { source_revision: body.p_source_revision, card: body.p_card };
        return rec.hop("supabase", SUPABASE_MS, ok({ status: "saved", card: body.p_card }));
      }
      if (answer === undefined) throw new Error(`unexpected ${url}`);
      return rec.hop("supabase", SUPABASE_MS, ok(answer));
    },
  });
  const t0 = performance.now();
  const response = await handle({
    headers: { authorization: "Bearer user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-1" } } },
    body: null,
  });
  const total = performance.now() - t0;
  assert.equal(response.statusCode, 200);
  summarize("close_session_handler", total, rec.events);
});

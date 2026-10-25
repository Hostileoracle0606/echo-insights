// How many network round trips does one get_relevant_memory call wait on in
// sequence? Every fake Supabase call (auth, table read, RPC) takes HOP_MS and
// the embedder takes EMBED_MS, so the elapsed time divided by HOP_MS is the
// number of sequential hops. Real latency ≈ hops × (edge→Postgres RTT) +
// embedding + ranking CPU + the phone→edge round trip.
//
// Run: deno test --allow-env supabase/functions/retrieve-memory/handler.latency.test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { Embedder } from "../_shared/embedder.ts";
import { createHandler, type DbClient, type RetrieveMemoryDeps } from "./handler.ts";

const HOP_MS = 50;
const EMBED_MS = 80;
const wait = <T>(value: T, ms = HOP_MS) => new Promise<T>((r) => setTimeout(() => r(value), ms));

const NOW = new Date().toISOString();
const ent = (id: string, name: string) => ({
  id, name, type: "person", description: null, mentions: 3, firstSeen: NOW, lastSeen: NOW, notebookCount: 2,
});
const userGraph = {
  entityCount: 2,
  relationCount: 1,
  entities: [ent("priya", "Priya"), ent("ci-fix", "CI fix")],
  relations: [{ id: "r1", source: "priya", target: "ci-fix", label: "owns" }],
};
const mentions = {
  total: 1,
  mentions: [{
    entryId: "e1", notebookId: "nb-old", notebookTitle: "Old", notebookStartedAt: NOW,
    conversationMode: "just_talk", createdAt: NOW, excerpt: "Priya said the CI fix is next",
    turnId: null, spokenAt: null,
  }],
};

function slowClient(log: string[]): DbClient {
  return {
    auth: { getUser: () => { log.push("auth.getUser"); return wait({ data: { user: { id: "u1" } }, error: null }); } },
    from: (table) => ({
      select: () => ({
        eq: (_c: string, id: string) => ({
          single: () => { log.push(`select ${table}`); return wait({ data: { id }, error: null }); },
        }),
      }),
    }),
    rpc: (fn) => {
      log.push(`rpc ${fn}`);
      const data = fn === "bump_retrieve_rate" ? true
        : fn === "get_user_graph" ? userGraph
        : fn === "get_entity_mentions" ? mentions
        : [];
      return wait({ data, error: null });
    },
  };
}

const slowEmbedder: Embedder = {
  modelId: "stub@1",
  embed: (texts) => wait(texts.map(() => new Array(384).fill(0.01)), EMBED_MS),
};

async function timeCall(body: unknown) {
  const log: string[] = [];
  const deps: RetrieveMemoryDeps = {
    userClient: () => slowClient(log),
    adminClient: () => slowClient(log),
    embedder: () => slowEmbedder,
    log: () => {},
  };
  const handler = createHandler(deps);
  const t0 = performance.now();
  const res = await handler(new Request("http://local/retrieve-memory", {
    method: "POST",
    headers: { Authorization: "Bearer jwt" },
    body: JSON.stringify(body),
  }));
  await res.json();
  return { ms: performance.now() - t0, status: res.status, calls: log };
}

Deno.test("user scope (live get_relevant_memory): sequential hops", async () => {
  const { ms, status, calls } = await timeCall({ query: "Priya and the CI fix", notebookId: "nb-open", scope: "user" });
  assertEquals(status, 200);
  const hops = Math.round((ms - EMBED_MS) / HOP_MS);
  console.log(`PERF retrieve_user_scope total=${ms.toFixed(0)}ms calls=${calls.length} sequentialHops≈${hops} (+1 embed)`);
  console.log(`PERF retrieve_user_scope order: ${calls.join(" → ")}`);
});

Deno.test("notebook scope (extraction's retrieval): sequential hops", async () => {
  const state = {
    entities: { priya: { ...ent("priya", "Priya"), metadata: {} } },
    relations: {},
    entries: [],
  };
  const { ms, status, calls } = await timeCall({ query: "Priya", notebookId: "nb-open", state });
  assertEquals(status, 200);
  const hops = Math.round((ms - EMBED_MS) / HOP_MS);
  console.log(`PERF retrieve_notebook_scope total=${ms.toFixed(0)}ms calls=${calls.length} sequentialHops≈${hops} (+1 embed)`);
});

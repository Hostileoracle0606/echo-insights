// The per-user search-index cache: reused for the same user and scope,
// never shared between users.
//
// Run: deno test --allow-env --no-check supabase/functions/retrieve-memory/handler.cache.test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createHandler, type DbClient, indexCacheSize, type RetrieveMemoryDeps } from "./handler.ts";

const NOW = new Date().toISOString();
const graph = {
  entityCount: 2,
  relationCount: 1,
  entities: [
    { id: "priya", name: "Priya", type: "person", description: null, mentions: 3, firstSeen: NOW, lastSeen: NOW, notebookCount: 1 },
    { id: "ci", name: "CI fix", type: "project", description: null, mentions: 2, firstSeen: NOW, lastSeen: NOW, notebookCount: 1 },
  ],
  relations: [{ id: "r1", source: "priya", target: "ci", label: "owns" }],
};

function client(userId: string, g: unknown = graph): DbClient {
  return {
    auth: { getUser: () => Promise.resolve({ data: { user: { id: userId } }, error: null }) },
    from: () => ({ select: () => ({ eq: (_c: string, id: string) => ({ single: () => Promise.resolve({ data: { id }, error: null }) }) }) }),
    rpc: (fn) => Promise.resolve({
      data: fn === "bump_retrieve_rate" ? true : fn === "get_user_graph" ? g : fn === "get_entity_mentions" ? { total: 0, mentions: [] } : [],
      error: null,
    }),
  };
}

async function ask(userId: string, query: string, g: unknown = graph) {
  const deps: RetrieveMemoryDeps = {
    userClient: () => client(userId, g),
    adminClient: () => client(userId, g),
    embedder: () => { throw new Error("no embedder locally"); },
    log: () => {},
  };
  const res = await createHandler(deps)(new Request("http://local/retrieve-memory", {
    method: "POST",
    headers: { Authorization: "Bearer jwt" },
    body: JSON.stringify({ query, notebookId: "nb-1", scope: "user" }),
  }));
  return { status: res.status, body: await res.json() };
}

Deno.test("one index per user and scope, reused across requests", async () => {
  const before = indexCacheSize();
  const first = await ask("user-a", "Priya");
  const again = await ask("user-a", "the CI fix");
  assertEquals(first.status, 200);
  assertEquals(again.status, 200);
  assertEquals(indexCacheSize(), before + 1);
  // Same results as an uncached first request would give.
  assertEquals(first.body.entityIds.includes("priya"), true);
  assertEquals(again.body.entityIds.includes("ci"), true);
});

Deno.test("a different user gets a separate index", async () => {
  const before = indexCacheSize();
  await ask("user-b", "Priya");
  assertEquals(indexCacheSize(), before + 1);
});

Deno.test("no match still answers (communities computed on demand)", async () => {
  const res = await ask("user-c", "zzz nothing matches");
  assertEquals(res.status, 200);
});

Deno.test("PERF cold vs warm recall at 1,000 entities", async () => {
  const n = 1000;
  const big = {
    entityCount: n,
    relationCount: n,
    entities: Array.from({ length: n }, (_, i) => ({
      id: `e${i}`, name: `Entity ${i}`, type: "concept",
      description: `Entity ${i} is something the user talks about.`,
      mentions: 1 + (i % 7), firstSeen: NOW, lastSeen: NOW, notebookCount: 1,
    })),
    relations: Array.from({ length: n }, (_, i) => ({
      id: `r${i}`, source: `e${i}`, target: `e${(i * 7 + 1) % n}`, label: "related_to",
    })),
  };
  const time = async (user: string, query: string) => {
    const t = performance.now();
    const res = await ask(user, query, big);
    assertEquals(res.status, 200);
    return performance.now() - t;
  };
  await time("warmup-jit", "Entity 1"); // JIT warm-up on a key of its own
  const cold = await time("perf-user", "Entity 3 and Entity 12");
  const warm: number[] = [];
  for (let i = 0; i < 5; i++) warm.push(await time("perf-user", `Entity ${i * 11} again`));
  warm.sort((a, b) => a - b);
  const noSeedCold = await time("perf-user-2", "zzz nothing matches");
  console.log(`PERF recall_cache n=${n} cold=${cold.toFixed(1)}ms warmMedian=${warm[2].toFixed(1)}ms noSeedCold=${noSeedCold.toFixed(1)}ms`);
});

import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createEdgeMemoryReranker } from "./memory-reranker-edge.ts";

Deno.test("the edge reranker scores each card's text and returns scores by id", async () => {
  const seen: string[][] = [];
  const reranker = createEdgeMemoryReranker({ score: async (q, cards) => { seen.push([q, ...cards]); return cards.map((c) => c.length); }, timeoutMs: 1000 });
  const scores = await reranker.rank("q", [{ id: "a", text: "xx" }, { id: "b", text: "xxxxx" }], new AbortController().signal);
  assertEquals([...scores], [["a", 2], ["b", 5]]);
  assertEquals(seen, [["q", "xx", "xxxxx"]]);
});

Deno.test("an aborted or slow edge rerank rejects so the caller falls back", async () => {
  const slow = createEdgeMemoryReranker({ score: () => new Promise(() => {}), timeoutMs: 20 });
  await assertRejects(() => slow.rank("q", [{ id: "a", text: "x" }], new AbortController().signal));
  const aborted = new AbortController();
  aborted.abort();
  await assertRejects(() => createEdgeMemoryReranker({ score: async () => [1], timeoutMs: 1000 }).rank("q", [{ id: "a", text: "x" }], aborted.signal));
});

Deno.test("a score count that doesn't match the cards is rejected", async () => {
  await assertRejects(() => createEdgeMemoryReranker({ score: async () => [1, 2], timeoutMs: 1000 }).rank("q", [{ id: "a", text: "x" }], new AbortController().signal));
});

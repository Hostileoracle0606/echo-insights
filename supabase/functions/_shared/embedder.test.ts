import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "./embedder.ts";

Deno.test("StubEmbedder is deterministic, 384-dim, normalized-ish", async () => {
  const e = new StubEmbedder();
  assertEquals(e.modelId, "stub@1");
  const [a] = await e.embed(["hello world"]);
  const [b] = await e.embed(["hello world"]);
  assertEquals(a.length, 384);
  assertEquals(a, b); // deterministic
});

Deno.test("StubEmbedder distinguishes different text", async () => {
  const e = new StubEmbedder();
  const [a] = await e.embed(["startup"]);
  const [b] = await e.embed(["completely different tokens here"]);
  assert(JSON.stringify(a) !== JSON.stringify(b));
});

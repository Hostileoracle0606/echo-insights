import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createReranker } from "./scorer.ts";

const dir = new URL(".", import.meta.url);
const manifest = JSON.parse(await Deno.readTextFile(new URL("manifest.json", dir)));
// The model binary is fetched by ml/reranker/deploy/fetch_model.sh, not committed.
const hasModel = await Deno.stat(new URL("model.int8.onnx", dir)).then(() => true, () => false);
const top = (xs: number[], k: number) => new Set([...xs.keys()].sort((a, b) => xs[b] - xs[a]).slice(0, k));

Deno.test({ name: "one batched run scores a pool like the trained model (same top-3 seeds)", ignore: !hasModel }, async () => {
  const rerank = createReranker({ model: () => Deno.readFile(new URL("model.int8.onnx", dir)), vocab: () => Deno.readTextFile(new URL("vocab.txt", dir)), maxLength: manifest.max_length, timeoutMs: 10_000 });
  for (const row of manifest.parity.rows) {
    const logits = await rerank(row.query, row.documents);
    assertEquals(logits.length, row.documents.length);
    assertEquals(top(logits, 3), top(row.torch, 3), row.id);
    assert(logits.every((x: number, i: number) => Math.abs(x - row.torch[i]) <= 0.5), row.id);
  }
});

Deno.test("an empty pool scores to nothing without loading the model", async () => {
  let loaded = false;
  const rerank = createReranker({ model: () => { loaded = true; return Promise.resolve(new Uint8Array()); }, vocab: () => Promise.resolve(""), maxLength: 256, timeoutMs: 50 });
  assertEquals(await rerank("q", []), []);
  assertEquals(loaded, false);
});

Deno.test("a reranker slower than its budget rejects, so the handler falls back", async () => {
  const rerank = createReranker({ model: () => new Promise(() => {}), vocab: () => Promise.resolve("[PAD]\n[UNK]\n[CLS]\n[SEP]"), maxLength: 256, timeoutMs: 20 });
  await assertRejects(() => rerank("q", ["doc"]), Error, "timed out");
});

Deno.test({ name: "a card scores the same alone as inside its pool (no cross-candidate quantisation effects)", ignore: !hasModel }, async () => {
  const rerank = createReranker({ model: () => Deno.readFile(new URL("model.int8.onnx", dir)), vocab: () => Deno.readTextFile(new URL("vocab.txt", dir)), maxLength: 256, timeoutMs: 10_000 });
  const row = manifest.parity.rows[0];
  const pooled = await rerank(row.query, row.documents);
  for (const [i, doc] of row.documents.slice(0, 3).entries()) {
    assertEquals((await rerank(row.query, [doc]))[0], pooled[i]);
  }
});

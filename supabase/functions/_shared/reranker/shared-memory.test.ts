// Supabase's edge runtime refuses shared WebAssembly memory. This file runs in
// its own isolate with shared memory disabled before onnxruntime loads, so the
// reranker must pick a single-threaded build to load and score at all.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const dir = new URL(".", import.meta.url);
const hasModel = await Deno.stat(new URL("model.int8.onnx", dir)).then(() => true, () => false);

Deno.test({ name: "the reranker loads and scores without shared WebAssembly memory", ignore: !hasModel }, async () => {
  const Original = WebAssembly.Memory;
  // deno-lint-ignore no-explicit-any
  (WebAssembly as any).Memory = function (descriptor: WebAssembly.MemoryDescriptor) {
    if (descriptor?.shared) throw new TypeError("Creating a shared memory is not supported");
    return new Original(descriptor);
  };
  try {
    const { createReranker } = await import("./scorer.ts");
    const rerank = createReranker({ model: () => Deno.readFile(new URL("model.int8.onnx", dir)), vocab: () => Deno.readTextFile(new URL("vocab.txt", dir)), maxLength: 256, timeoutMs: 20_000 });
    const scores = await rerank("where does Aurelio live", ["Aurelio Sutherland (person)\nAurelio Sutherland --lives_in--> Mossley", "Pickle (person)\nA grey tabby cat."]);
    assertEquals(scores.length, 2);
    assertEquals(scores[0] > scores[1], true);
  } finally {
    // deno-lint-ignore no-explicit-any
    (WebAssembly as any).Memory = Original;
  }
});

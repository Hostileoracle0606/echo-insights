import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { loadVerifiedModel } from "./model-artifact.ts";

const bytes = new TextEncoder().encode("model bytes");
const sha = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");

Deno.test("the model comes from the store when it matches the pinned hash", async () => {
  const paths: string[] = [];
  const got = await loadVerifiedModel({ sha256: sha, download: async (path) => { paths.push(path); return bytes; } });
  assertEquals(got, bytes);
  assertEquals(paths, [`reranker/${sha}.onnx`]);
});

Deno.test("a model whose hash differs from the pin is refused", async () => {
  await assertRejects(() => loadVerifiedModel({ sha256: "0".repeat(64), download: async () => bytes }), Error, "sha256");
});

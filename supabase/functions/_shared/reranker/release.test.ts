// Release check for the served reranker: the manifest must pin a registry
// revision, and its recorded evaluation must clear the release bar. Written by
// ml/reranker/lumen_reranker/release.py from the evaluation runs.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const dir = new URL(".", import.meta.url);
const manifest = JSON.parse(await Deno.readTextFile(new URL("manifest.json", dir)));

Deno.test("the served model is pinned to a registry revision and a hash", () => {
  assert(/^[0-9a-f]{40}$/.test(manifest.registry.revision));
  assert(/^[0-9a-f]{64}$/.test(manifest.sha256));
  assertEquals(manifest.registry.path, "edge/model.int8.onnx");
});

Deno.test("on validation it beats current search on complete evidence, interval clear of the bar", () => {
  const { validation, budget } = manifest.release;
  assert(validation.allAt10.reranked > validation.allAt10.search);
  assert(validation.allAt10.delta.lo > budget.minCompleteEvidenceDeltaLo);
});

Deno.test("its measured edge p95 fits the latency budget", () => {
  assert(manifest.release.edgeLatencyMs.p95 <= manifest.release.budget.edgeP95Ms);
});

Deno.test("served from the reranker service, its measured round-trip p95 fits that budget", () => {
  // The hosted path (RERANKER_SERVICE_URL); retrieve-memory's rerank timeout should be the budget.
  const { serviceLatencyMs, budget } = manifest.release;
  assert(serviceLatencyMs.n >= 20, "measure at least 20 warm calls");
  assert(serviceLatencyMs.p95 <= budget.serviceP95Ms);
});

Deno.test("a local model file, when present, is the pinned one", async () => {
  const bytes = await Deno.readFile(new URL("model.int8.onnx", dir)).catch(() => null);
  if (!bytes) return;
  const hex = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
  assertEquals(hex, manifest.sha256);
});

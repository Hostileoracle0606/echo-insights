import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { build } from "esbuild";

import { bearerMatches, createHandler, parseRequest } from "../lambda/memory-reranker/core.mjs";
import { sanitizeLogFields } from "../lambda/memory-reranker/safe-log.mjs";
import { buildPackage } from "../scripts/build-memory-reranker.mjs";

const TOKEN = "test-token-not-a-secret";
const MARKER = "Quillmont-private-marker";
const shared = fileURLToPath(new URL("../../supabase/functions/_shared/reranker/", import.meta.url));
const manifest = JSON.parse(readFileSync(join(shared, "manifest.json"), "utf8"));
// The model binary is fetched by ml/reranker/deploy/fetch_model.sh, not committed.
const hasModel = existsSync(join(shared, "model.int8.onnx"));

const event = (body, { auth = `Bearer ${TOKEN}`, method = "POST" } = {}) => ({
  requestContext: { http: { method } },
  headers: auth ? { authorization: auth } : {},
  body: typeof body === "string" ? body : JSON.stringify(body),
  isBase64Encoded: false,
});
const harness = (score = async (_q, cards) => cards.map((_, i) => 1 - i)) => {
  const lines = [];
  const handle = createHandler({ score, token: async () => TOKEN, log: (fields) => lines.push(JSON.stringify(sanitizeLogFields(fields))) });
  return { handle, lines };
};
const request = { query: `Where does ${MARKER} live?`, documents: [{ id: "candidate-0", text: `${MARKER} (person)` }, { id: "candidate-1", text: "work (activity)" }] };

test("scores every candidate under its request-local id", async () => {
  const { handle } = harness();
  const res = await handle(event(request));
  assert.equal(res.statusCode, 200);
  assert.deepEqual(JSON.parse(res.body), { scores: [{ id: "candidate-0", score: 1 }, { id: "candidate-1", score: 0 }] });
});

test("a missing or wrong bearer token is refused before anything is scored", async () => {
  let scored = false;
  const { handle } = harness(async (_q, cards) => { scored = true; return cards.map(() => 0); });
  for (const auth of [null, "Bearer wrong", TOKEN, `Basic ${TOKEN}`]) {
    assert.equal((await handle(event(request, { auth }))).statusCode, 401);
  }
  assert.equal(scored, false);
  assert.equal(bearerMatches(`Bearer ${TOKEN}`, TOKEN), true);
  assert.equal(bearerMatches(`Bearer ${TOKEN}`, ""), false);
});

test("only POST is served", async () => {
  assert.equal((await harness().handle(event(request, { method: "GET" }))).statusCode, 405);
});

test("requests outside the adapter's limits are refused", async () => {
  const doc = (id, text = "card") => ({ id, text });
  const bad = [
    "not json",
    { query: "", documents: [doc("a")] },
    { query: "q".repeat(2001), documents: [doc("a")] },
    { query: "q", documents: [] },
    { query: "q", documents: Array.from({ length: 33 }, (_, i) => doc(`c${i}`)) },
    { query: "q", documents: [doc("a"), doc("a")] },
    { query: "q", documents: [doc("a", "x".repeat(8001))] },
    { query: "q", documents: [doc("x".repeat(101))] },
  ];
  const { handle } = harness();
  for (const body of bad) assert.equal((await handle(event(body))).statusCode, 400, JSON.stringify(body).slice(0, 60));
  assert.equal((await handle(event("x".repeat(400_001)))).statusCode, 413);
  assert.ok(parseRequest({ query: "q", documents: Array.from({ length: 32 }, (_, i) => doc(`c${i}`)) }));
});

test("logs carry counts and timings, never the query or a card", async () => {
  const { handle, lines } = harness();
  await handle(event(request));
  await handle(event(request, { auth: "Bearer wrong" }));
  await handle(event({ ...request, documents: [] }));
  assert.equal(lines.length, 3);
  assert.equal(lines.join("").includes(MARKER), false);
  assert.match(lines[0], /"event":"reranked".*"candidates":2/);
});

test("a scorer that returns the wrong number of scores fails the request", async () => {
  const { handle } = harness(async () => [1]);
  await assert.rejects(() => handle(event(request)), TypeError);
});

test("the built package keeps only the target's onnxruntime binary", { skip: !hasModel }, async () => {
  const out = mkdtempSync(join(tmpdir(), "memory-reranker-linux-"));
  try {
    await buildPackage(out, "linux-arm64");
    const bin = join(out, "node_modules", "onnxruntime-node", "bin", "napi-v6");
    assert.ok(existsSync(join(bin, "linux", "arm64", "onnxruntime_binding.node")));
    assert.equal(existsSync(join(bin, "darwin")), false);
    assert.equal(existsSync(join(bin, "linux", "x64")), false);
    assert.ok(existsSync(join(out, "model.int8.onnx")) && existsSync(join(out, "vocab.txt")));
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test("native onnxruntime scores pools like the trained model (same top-3 seeds)", { skip: !hasModel }, async () => {
  // The host's own package, with the scorer bundled next to it the way the Lambda's is.
  const out = mkdtempSync(join(tmpdir(), "memory-reranker-host-"));
  try {
    await buildPackage(out, `${process.platform}-${process.arch}`);
    await build({
      entryPoints: [fileURLToPath(new URL("../lambda/memory-reranker/scorer.mjs", import.meta.url))],
      outfile: join(out, "scorer.mjs"), bundle: true, platform: "node", format: "esm", external: ["onnxruntime-node"], logLevel: "warning",
    });
    const { loadScorer } = await import(join(out, "scorer.mjs"));
    const score = await loadScorer({ modelPath: join(out, "model.int8.onnx"), vocabPath: join(out, "vocab.txt"), sha256: manifest.sha256, maxLength: manifest.max_length });
    const top = (xs, k) => new Set([...xs.keys()].sort((a, b) => xs[b] - xs[a]).slice(0, k));
    for (const row of manifest.parity.rows) {
      const logits = await score(row.query, row.documents);
      assert.deepEqual(top(logits, 3), top(row.torch, 3), row.id);
      assert.ok(logits.every((x, i) => Math.abs(x - row.torch[i]) <= 0.5), row.id);
      // A card scores the same alone as in its pool: one pair per run.
      assert.equal((await score(row.query, [row.documents[1]]))[0], logits[1], row.id);
    }
    await assert.rejects(
      () => loadScorer({ modelPath: join(out, "model.int8.onnx"), vocabPath: join(out, "vocab.txt"), sha256: "0".repeat(64), maxLength: 256 }),
      /does not match its pin/,
    );
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

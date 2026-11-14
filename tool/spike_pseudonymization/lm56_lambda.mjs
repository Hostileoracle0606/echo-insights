#!/usr/bin/env node
// LM-56 measurement: runs the real extract-graph handler on one request body
// (stdin) and prints its response ({statusCode, body}) on stdout. Called by
// lm56_measure_test.dart through the app's real ExtractGraphService.
//
// The Gemini key is read from echo-insights/.env and only ever sent as a
// header; it is never printed, logged or written. Model answers are cached by
// request hash in lm56_cache/ (synthetic data only). Pacing: 15 s between
// calls; a 429 waits once on its retry delay; a daily quota stops all calls.
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createExtractGraphHandler } from "../../infra/lambda/extract-graph/core.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const CACHE = join(here, "lm56_cache");
const LEDGER = join(CACHE, "ledger.jsonl");
const STOP = join(CACHE, "STOP");
const ENV_PATH = "/Users/trinabgoswamy/Developer/echo-insights/.env";
const MAX_CALLS = 8;
mkdirSync(CACHE, { recursive: true });

function loadKey() {
  const m = readFileSync(ENV_PATH, "utf8").match(/^\s*GEMINI_API_KEY\s*=\s*(.+?)\s*$/m);
  if (!m) throw new Error("GEMINI_API_KEY not found in env file");
  return m[1].replace(/^["']|["']$/g, "");
}

const ledger = () =>
  existsSync(LEDGER)
    ? readFileSync(LEDGER, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l))
    : [];

const reply = (status, body) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
});

/** Gemini behind the cache, the pacing and the call budget. */
async function gemini(url, init) {
  const body = JSON.parse(init.body);
  const hash = createHash("sha256").update(init.body).digest("hex").slice(0, 16);
  const tag = process.env.LM56_TAG ?? "case";
  const file = join(CACHE, `${tag}.json`);
  if (existsSync(file)) {
    const cached = JSON.parse(readFileSync(file, "utf8"));
    if (cached.requestHash === hash) return reply(200, cached.response);
  }
  // Dry run: keep the request to check the prompt, call nothing.
  if (process.env.LM56_DRY) {
    writeFileSync(join(CACHE, `${tag}.dry.json`), JSON.stringify({ tag, request: body }, null, 1));
    return reply(503, {});
  }
  if (existsSync(STOP)) return reply(503, {});
  const calls = ledger();
  if (calls.length >= MAX_CALLS) return reply(503, {});
  const last = calls.at(-1);
  if (last) {
    const wait = 15000 - (Date.now() - Date.parse(last.at));
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  }
  const key = loadKey();
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": key },
      body: init.body,
      signal: AbortSignal.timeout(60000),
    });
    let quotaId = null;
    let retry = null;
    let json = null;
    try {
      json = await res.json();
    } catch {}
    if (!res.ok) {
      const det = json?.error?.details ?? [];
      retry = det.find((d) => d.retryDelay)?.retryDelay ?? null;
      quotaId = det.flatMap((d) => d.violations ?? []).map((v) => v.quotaId).filter(Boolean).join(",") || null;
    }
    appendFileSync(LEDGER, `${JSON.stringify({ at: new Date().toISOString(), tag, status: res.status, quotaId, retryDelay: retry })}\n`);
    if (res.ok) {
      writeFileSync(file, JSON.stringify({ tag, requestHash: hash, request: body, response: json }, null, 1));
      return reply(200, json);
    }
    const daily = Boolean(quotaId && /PerDay/i.test(quotaId));
    const secs = retry ? Math.ceil(parseFloat(retry)) : null;
    if (res.status === 429 && !daily && attempt === 0 && secs != null && secs <= 90) {
      await new Promise((r) => setTimeout(r, (secs + 2) * 1000));
      continue;
    }
    writeFileSync(STOP, JSON.stringify({ tag, status: res.status, quotaId, daily }));
    return reply(res.status, {});
  }
  return reply(503, {});
}

const handle = createExtractGraphHandler({
  supabaseUrl: "https://measure.invalid",
  publishableKey: "measure",
  model: "gemini-2.5-flash",
  getPermanentCredential: async () => "unused-the-fetch-below-adds-the-real-key",
  acquireExtraction: async () => ({ status: "acquired" }),
  completeExtraction: async ({ patch }) => ({ status: "completed", patch }),
  fetchImpl: async (input, init = {}) => {
    const url = String(input);
    if (url.startsWith("https://generativelanguage.googleapis.com/")) return gemini(url, init);
    // The notebook ownership check: the measurement owns its notebook.
    return reply(200, [{ id: "measure" }]);
  },
  sleep: async () => {},
});

let input = "";
for await (const chunk of process.stdin) input += chunk;
const { notebookId, body } = JSON.parse(input);
const response = await handle({
  headers: { authorization: "Bearer measure" },
  pathParameters: { notebookId },
  requestContext: { authorizer: { lambda: { userId: "measure-user" } } },
  body,
});
process.stdout.write(JSON.stringify({ statusCode: response.statusCode, body: response.body }));

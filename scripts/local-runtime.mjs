// The notebook runtime (infra/lambda) on localhost, against a local Supabase.
//
// Run: node scripts/local-runtime.mjs   (needs SUPABASE_URL,
//      SUPABASE_PUBLISHABLE_KEY and GEMINI_API_KEY in the environment)
//
// Hosts the same handler cores the AWS stack deploys, behind the same
// routes, with the API Gateway pieces replaced: the Supabase authorizer runs
// in-process, the Gemini credential comes from GEMINI_API_KEY instead of
// Secrets Manager, and the extraction cache is an in-memory map instead of
// DynamoDB. For local testing only; never point it at production.
import { createServer } from "node:http";

import { createSupabaseAuthorizer } from "../infra/lambda/supabase-authorizer/core.mjs";
import { createLiveSessionHandler } from "../infra/lambda/live-session/core.mjs";
import { createExtractGraphHandler } from "../infra/lambda/extract-graph/core.mjs";
import { createCloseSessionHandler } from "../infra/lambda/close-session/core.mjs";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment value: ${name}`);
  return value;
}

const supabaseUrl = required("SUPABASE_URL");
const publishableKey = required("SUPABASE_PUBLISHABLE_KEY");
const geminiKey = required("GEMINI_API_KEY");
const port = Number(process.env.PORT ?? 8787);
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(supabaseUrl)) {
  throw new Error(`local-runtime only runs against a local Supabase, not ${supabaseUrl}`);
}

const getPermanentCredential = async () => geminiKey;
const shared = { supabaseUrl, publishableKey, fetchImpl: fetch, getPermanentCredential };

// The DynamoDB claim/lease protocol from extract-graph/index.mjs, in memory.
const extractions = new Map();
function observed(record, inputHash, now) {
  if (record.inputHash !== inputHash) return { status: "mismatch" };
  if (record.status === "completed") return { status: "completed", patch: record.patch };
  return { status: "pending", retryAfterMs: Math.max(250, Math.min(2_000, record.leaseExpiresAt - now)) };
}

const authorize = createSupabaseAuthorizer(shared);
const liveSession = createLiveSessionHandler({
  ...shared,
  model: "gemini-3.1-flash-live-preview",
  userStartWindowSeconds: "600",
});
const extractGraph = createExtractGraphHandler({
  ...shared,
  model: "gemini-2.5-flash",
  acquireExtraction: async ({ id, inputHash, ownerToken, now, leaseExpiresAt }) => {
    const record = extractions.get(id);
    const free = !record || (record.status === "pending" && record.inputHash === inputHash && record.leaseExpiresAt <= now);
    if (!free) return observed(record, inputHash, now);
    extractions.set(id, { status: "pending", inputHash, ownerToken, leaseExpiresAt });
    return { status: "acquired" };
  },
  completeExtraction: async ({ id, inputHash, ownerToken, patch }) => {
    const record = extractions.get(id);
    if (!record || record.status !== "pending" || record.inputHash !== inputHash || record.ownerToken !== ownerToken) {
      return observed(record ?? { inputHash: "" }, inputHash, Date.now());
    }
    extractions.set(id, { status: "completed", inputHash, patch });
    return { status: "completed", patch };
  },
});
const closeSession = createCloseSessionHandler({ ...shared, model: "gemini-2.5-flash" });

// The four routes of infra/lib/infra-stack.ts.
const routes = [
  [/^\/v1\/notebooks\/([^/]+)\/live-sessions$/, liveSession],
  [/^\/v1\/live-sessions$/, liveSession],
  [/^\/v1\/notebooks\/([^/]+)\/extractions$/, extractGraph],
  [/^\/v1\/notebooks\/([^/]+)\/close$/, closeSession],
];

const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-allow-methods": "OPTIONS, POST",
};

createServer(async (req, res) => {
  const started = Date.now();
  const path = new URL(req.url, "http://local").pathname;
  const finish = (statusCode, headers, body) => {
    res.writeHead(statusCode, { ...cors, ...headers });
    res.end(body);
    console.log(`${req.method} ${path} → ${statusCode} (${Date.now() - started} ms)`);
  };
  if (req.method === "OPTIONS") return finish(204, {}, "");
  const match = routes.find(([pattern]) => pattern.test(path));
  if (!match || req.method !== "POST") return finish(404, { "content-type": "application/json" }, '{"error":"not_found"}');

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const [pattern, handler] = match;
  const notebookId = path.match(pattern)[1];
  const event = {
    headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)])),
    pathParameters: notebookId ? { notebookId: decodeURIComponent(notebookId) } : undefined,
    body: Buffer.concat(chunks).toString("utf8"),
    isBase64Encoded: false,
  };

  try {
    const auth = await authorize(event);
    if (!auth.isAuthorized) return finish(401, { "content-type": "application/json" }, '{"message":"Unauthorized"}');
    event.requestContext = { authorizer: { lambda: auth.context } };
    const result = await handler(event);
    finish(result.statusCode ?? 200, result.headers ?? {}, result.body ?? "");
  } catch (error) {
    console.error(error);
    finish(500, { "content-type": "application/json" }, '{"error":"internal"}');
  }
}).listen(port, "0.0.0.0", () => {
  console.log(`local notebook runtime on http://127.0.0.1:${port} → ${supabaseUrl}`);
});

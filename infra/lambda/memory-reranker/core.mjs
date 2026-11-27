// Request handling for the memory reranker service, as retrieve-memory's HTTP
// adapter (supabase/functions/retrieve-memory/memory-reranker.ts) calls it:
//
//   POST {query, documents: [{id, text}]}  with  authorization: Bearer <token>
//   200  {scores: [{id, score}]}           one per document
//
// Ids are request-local ("candidate-3"): the adapter never sends graph ids.
// The query and cards are journal content, so nothing here logs them (LM-44).
import { createHash, timingSafeEqual } from "node:crypto";

// The adapter's own limits, so anything it sends is accepted and nothing larger is.
const MAX_CANDIDATES = 32;
const MAX_QUERY_CHARS = 2000;
const MAX_DOCUMENT_CHARS = 8000;
const MAX_ID_CHARS = 100;
const MAX_BODY_BYTES = 400_000;

const json = (statusCode, body) => ({
  statusCode,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
  body: JSON.stringify(body),
});

const digest = (value) => createHash("sha256").update(value).digest();

/** Constant-time: hashing first makes both sides the same length. */
export function bearerMatches(header, token) {
  if (typeof header !== "string" || !header.startsWith("Bearer ") || !token) return false;
  return timingSafeEqual(digest(header.slice("Bearer ".length)), digest(token));
}

/** The request's `{query, documents}`, or null when it isn't one the adapter would send. */
export function parseRequest(body) {
  if (!body || typeof body !== "object") return null;
  const { query, documents } = body;
  if (typeof query !== "string" || !query.trim() || query.length > MAX_QUERY_CHARS) return null;
  if (!Array.isArray(documents) || documents.length < 1 || documents.length > MAX_CANDIDATES) return null;
  const ids = new Set();
  for (const document of documents) {
    if (!document || typeof document !== "object") return null;
    const { id, text } = document;
    if (typeof id !== "string" || !id || id.length > MAX_ID_CHARS || ids.has(id)) return null;
    if (typeof text !== "string" || !text || text.length > MAX_DOCUMENT_CHARS) return null;
    ids.add(id);
  }
  return { query, documents };
}

/**
 * `score(query, cards)` → one logit per card; `token()` → the bearer secret;
 * `log(fields)` → a content-free log line (safe-log).
 */
export function createHandler({ score, token, log, now = () => performance.now() }) {
  let served = 0;
  return async (event) => {
    const started = now();
    if (event?.requestContext?.http?.method !== "POST") return json(405, { error: "method not allowed" });
    if (!bearerMatches(event.headers?.authorization, await token())) {
      log({ event: "rejected", code: "unauthorized" });
      return json(401, { error: "unauthorized" });
    }
    const raw = event.isBase64Encoded ? Buffer.from(event.body ?? "", "base64").toString("utf8") : event.body ?? "";
    if (Buffer.byteLength(raw) > MAX_BODY_BYTES) return json(413, { error: "request too large" });
    let request = null;
    try {
      request = parseRequest(JSON.parse(raw));
    } catch {
      request = null;
    }
    if (!request) {
      log({ event: "rejected", code: "invalid_request" });
      return json(400, { error: "invalid request" });
    }
    const scoreStarted = now();
    const logits = await score(request.query, request.documents.map(({ text }) => text));
    if (logits.length !== request.documents.length || !logits.every(Number.isFinite)) {
      throw new TypeError("Expected one finite score per candidate");
    }
    served += 1;
    log({
      event: "reranked",
      candidates: request.documents.length,
      scoreMs: Math.round(now() - scoreStarted),
      totalMs: Math.round(now() - started),
      firstOnWorker: served === 1,
    });
    return json(200, { scores: request.documents.map(({ id }, i) => ({ id, score: logits[i] })) });
  };
}

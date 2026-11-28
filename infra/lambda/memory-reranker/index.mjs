// Lambda entry point (Function URL) for the memory reranker. The model loads
// during init, which gets a full CPU burst, so the first request only scores.
// A scheduled {warm: true} invoke (MemoryRerankerStack) keeps a container
// loaded, so a quiet spell doesn't cost the next recall a cold start.
// The request logic and its tests are in core.mjs.
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

import { createHandler } from "./core.mjs";
import { errorClass, guardHandler, safeLog } from "./safe-log.mjs";
import { loadScorer } from "./scorer.mjs";
import manifest from "../../../supabase/functions/_shared/reranker/manifest.json" with { type: "json" };

const SOURCE = "memory-reranker";
const log = (fields) => safeLog(SOURCE, fields);

const initStarted = performance.now();
const ready = loadScorer({
  modelPath: new URL("./model.int8.onnx", import.meta.url),
  vocabPath: new URL("./vocab.txt", import.meta.url),
  sha256: manifest.sha256,
  maxLength: manifest.max_length,
}).then(
  (score) => {
    log({ event: "model_loaded", ms: Math.round(performance.now() - initStarted) });
    return score;
  },
  (error) => {
    log({ event: "model_load_failed", errorClass: errorClass(error) });
    throw error;
  },
);
// Finish loading during init (boosted CPU, not billed to a request); a failure
// is reported above and each request then fails with a 500.
await ready.catch(() => {});

const secrets = new SecretsManagerClient({});
let tokenValue = null;
const token = () => (tokenValue ??= secrets
  .send(new GetSecretValueCommand({ SecretId: process.env.RERANKER_TOKEN_SECRET_ARN }))
  .then((result) => {
    if (!result.SecretString) throw new Error("Reranker token is unavailable");
    return result.SecretString;
  })
  .catch((error) => {
    tokenValue = null;
    throw error;
  }));

const serve = guardHandler(
  SOURCE,
  createHandler({ score: async (query, cards) => (await ready)(query, cards), token, log }),
  () => ({ statusCode: 500, headers: { "content-type": "application/json" }, body: '{"error":"reranker failed"}' }),
);

// A direct invoke (never the URL, whose events carry requestContext) with {warm: true}.
export const handler = (event) => (event?.warm === true && !event.requestContext ? ready.then(() => ({ warm: true })) : serve(event));

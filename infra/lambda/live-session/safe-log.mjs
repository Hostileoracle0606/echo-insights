// The only way a handler writes to CloudWatch (LM-44). Journal content must
// never reach a log line: no transcripts, card text, entity names, model
// prompts or model error bodies. This file is copied into each Lambda
// directory (each is bundled on its own); test/safe-log.test.mjs keeps the
// copies identical.
//
// Numbers and booleans are always safe. A string survives only under a key
// on the allowlist and only if it looks like an id or code, never prose.

const SAFE_STRING_KEYS = new Set([
  "event",
  "notebookId",
  "userId",
  "turnId",
  "code",
  "outcome",
  "mode",
  "stage",
  "errorClass",
  "rateLimitedBy",
]);
const SAFE_STRING = /^[A-Za-z0-9_.:-]{1,64}$/;

/** The error's class name, or "unknown". Never its message, which can echo content. */
export function errorClass(error) {
  const name = error instanceof Error ? error.name : undefined;
  return typeof name === "string" && SAFE_STRING.test(name) ? name : "unknown";
}

export function sanitizeLogFields(fields) {
  const clean = {};
  let dropped = 0;
  for (const [key, value] of Object.entries(fields ?? {})) {
    if (value === undefined) continue;
    if (typeof value === "number" && Number.isFinite(value)) clean[key] = value;
    else if (typeof value === "boolean") clean[key] = value;
    else if (typeof value === "string" && SAFE_STRING_KEYS.has(key) && SAFE_STRING.test(value)) {
      clean[key] = value;
    } else dropped += 1;
  }
  if (dropped > 0) clean.droppedFields = dropped;
  return clean;
}

export function safeLog(source, fields, sink = console.log) {
  sink(JSON.stringify({ source, ...sanitizeLogFields(fields) }));
}

/**
 * Wraps a handler so a throw that escaped its own error handling is logged by
 * class only (the Lambda runtime would otherwise log the message and stack)
 * and answered with `fallback()`.
 */
export function guardHandler(source, handle, fallback, report = (fields) => safeLog(source, fields)) {
  return async (event) => {
    try {
      return await handle(event);
    } catch (error) {
      report({ event: "unhandled", errorClass: errorClass(error) });
      return fallback();
    }
  };
}

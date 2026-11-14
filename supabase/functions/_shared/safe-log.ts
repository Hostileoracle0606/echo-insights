// The only way an edge function writes to its log (LM-44). Journal content
// (transcripts, card text, entity names, model prompts, model error bodies)
// must never reach a log line.
//
// Numbers and booleans are always safe. A string survives only under a key on
// the allowlist and only if it looks like an id or code, never prose.

const SAFE_STRING_KEYS = new Set([
  "fn",
  "event",
  "notebookId",
  "userId",
  "scope",
  "stage",
  "code",
  "error",
  "errorClass",
  "qHash",
]);
const SAFE_STRING = /^[A-Za-z0-9_.:-]{1,64}$/;

/** The error's class name, or "unknown". Never its message, which can echo content. */
export function errorClass(error: unknown): string {
  const name = error instanceof Error ? error.name : undefined;
  return typeof name === "string" && SAFE_STRING.test(name) ? name : "unknown";
}

export function sanitizeLogFields(fields: Record<string, unknown>): Record<string, unknown> {
  const clean: Record<string, unknown> = {};
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

export function safeLog(
  fn: string,
  fields: Record<string, unknown>,
  sink: (line: string) => void = (line) => console.log(line),
): void {
  sink(JSON.stringify({ fn, ...sanitizeLogFields(fields) }));
}

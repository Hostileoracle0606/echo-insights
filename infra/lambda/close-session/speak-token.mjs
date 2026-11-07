// The speak step's ticket (LM-56). The brief's v2 write returns a short-lived
// token signed by the runtime; the speak request must carry it, and the line
// it asks to hear must be the written line with only its names changed. So
// the route speaks only lines it wrote itself, for that user, notebook and
// revision, within a few minutes: never a free text-to-speech proxy.
//
// The token is not single use. Once the app saves the brief, a repeated
// speak for that revision is "unchanged" (the stored brief covers it), so a
// replay can only cost a TTS call inside the token's lifetime.
import { createHmac, timingSafeEqual } from "node:crypto";

export const speakTokenTtlMs = 10 * 60 * 1000;

const keyFor = (secret) => createHmac("sha256", secret).update("lumen-speak-token-v1").digest();
const b64 = (buffer) => Buffer.from(buffer).toString("base64url");

/** Signs { notebookId, userId, revision, line, expiresAt } with [secret]. */
export function signSpeakToken(secret, { notebookId, userId, revision, line, expiresAt }) {
  const payload = b64(JSON.stringify({ n: notebookId, u: userId, r: revision, l: line, e: expiresAt }));
  const mac = b64(createHmac("sha256", keyFor(secret)).update(payload).digest());
  return `${payload}.${mac}`;
}

/** The token's fields if its signature holds and it hasn't expired, else null. */
export function readSpeakToken(secret, token, now) {
  if (typeof token !== "string") return null;
  const [payload, mac, extra] = token.split(".");
  if (!payload || !mac || extra !== undefined) return null;
  const expected = createHmac("sha256", keyFor(secret)).update(payload).digest();
  let given;
  try {
    given = Buffer.from(mac, "base64url");
  } catch {
    return null;
  }
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  let fields;
  try {
    fields = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (
    typeof fields?.n !== "string" ||
    typeof fields?.u !== "string" ||
    !Number.isSafeInteger(fields?.r) ||
    typeof fields?.l !== "string" ||
    typeof fields?.e !== "number" ||
    fields.e < now
  ) {
    return null;
  }
  return { notebookId: fields.n, userId: fields.u, revision: fields.r, line: fields.l };
}

// A run of capitalised words (a name, with any possessive), or of letters
// from a script without case (美咲): the places a stand-in can sit.
const nameRun =
  /(\p{Lu}[\p{L}\p{M}'’-]*(?:\s+\p{Lu}[\p{L}\p{M}'’-]*)*|[\p{Lo}][\p{Lo}\p{M}]*)/u;
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * True when [real] is [written] with only its names changed: every
 * capitalised run (and every run of caseless letters) in the written line
 * may be any short text; everything else must be the same.
 */
export function sameLineButNames(written, real) {
  const parts = written.split(nameRun);
  const pattern = parts
    .map((part, index) => (index % 2 === 1 ? "\\S.{0,80}?" : escape(part)))
    .join("");
  return new RegExp(`^${pattern}$`, "su").test(real);
}

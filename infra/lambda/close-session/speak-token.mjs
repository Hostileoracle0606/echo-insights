// The speak step's ticket (LM-56). The brief's v2 write returns a short-lived
// token signed by the runtime; the speak request must carry it, and the line
// it asks to hear must be the written line with each stand-in replaced by
// one of the user's own entity names (read with their token), everything
// else identical. So the route speaks only lines it wrote itself, for that
// user, notebook and revision, within a few minutes, with names from that
// user's graph: never a free text-to-speech proxy.
//
// The token is not single use. Once the app saves the brief, a repeated
// speak for that revision is "unchanged" (the stored brief covers it), so a
// replay can only cost a TTS call inside the token's lifetime.
import { createHmac, timingSafeEqual } from "node:crypto";

export const speakTokenTtlMs = 10 * 60 * 1000;

const keyFor = (secret) => createHmac("sha256", secret).update("lumen-speak-token-v1").digest();
const b64 = (buffer) => Buffer.from(buffer).toString("base64url");

/**
 * Signs { notebookId, userId, revision, line, slots, expiresAt } with
 * [secret]. [slots] are the stand-ins' token spans in [line] (slotSpans).
 */
export function signSpeakToken(secret, { notebookId, userId, revision, line, slots, expiresAt }) {
  const payload = b64(
    JSON.stringify({ n: notebookId, u: userId, r: revision, l: line, s: slots, e: expiresAt }),
  );
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
    !Array.isArray(fields?.s) ||
    typeof fields?.e !== "number" ||
    fields.e < now
  ) {
    return null;
  }
  return {
    notebookId: fields.n,
    userId: fields.u,
    revision: fields.r,
    line: fields.l,
    slots: fields.s,
  };
}

// Words and single punctuation marks. A plain character-class scan: it
// cannot backtrack, whatever the input.
const tokenPattern = /[\p{L}\p{M}\p{N}]+|[^\s\p{L}\p{M}\p{N}]/gu;

/** The line as tokens (words, and each punctuation mark on its own). */
export function tokenize(line) {
  return String(line).match(tokenPattern) ?? [];
}

const lower = (tokens) => tokens.map((t) => t.toLowerCase());

/**
 * Where the stand-ins sit in [line]: [start, end) token spans, left to right,
 * longest stand-in first, matched case-insensitively. [standIns] are the
 * stand-ins the app swapped into the request (from its name map).
 */
export function slotSpans(line, standIns) {
  const tokens = lower(tokenize(line));
  const forms = standIns
    .map((s) => lower(tokenize(s)))
    .filter((t) => t.length > 0)
    .sort((a, b) => b.length - a.length);
  const spans = [];
  // At most [maxSlots]: past that the words stay literal, and a line whose
  // names changed there fails the check (the app then saves it without audio).
  for (let i = 0; i < tokens.length && spans.length < maxSlots; ) {
    const hit = forms.find((f) => f.every((t, k) => tokens[i + k] === t));
    if (hit) {
      spans.push([i, i + hit.length]);
      i += hit.length;
    } else {
      i += 1;
    }
  }
  return spans;
}

// Bounds on what the check spends, whatever the user's graph or the line
// holds: a name is at most this many words (and characters), a row brings at
// most this many aliases, a line at most this many slots.
export const maxNameTokens = 8;
export const maxNameChars = 100;
export const maxAliasesPerRow = 20;
export const maxSlots = 16;

/**
 * The names a slot may take, from `entities` rows ({ name, aliases }): one
 * Set entry per name, lowercase, its words joined by single spaces. Names
 * over [maxNameTokens] words or [maxNameChars] characters are dropped, and
 * at most [maxAliasesPerRow] aliases are taken from a row.
 */
export function nameSet(rows) {
  const names = new Set();
  for (const row of Array.isArray(rows) ? rows : []) {
    const aliases = Array.isArray(row?.aliases) ? row.aliases.slice(0, maxAliasesPerRow) : [];
    for (const name of [row?.name, ...aliases]) {
      if (typeof name !== "string" || name.length > maxNameChars) continue;
      const tokens = tokenize(name.toLowerCase());
      if (tokens.length === 0 || tokens.length > maxNameTokens) continue;
      names.add(tokens.join(" "));
    }
  }
  return names;
}

/**
 * True when [real] is [written] with each slot (a stand-in's span, from the
 * signed token) replaced by one of [names] (a [nameSet]: the user's own
 * entity names and aliases), compared case-insensitively, and every other
 * token identical. One pass over the written tokens, keeping the set of
 * reachable positions in [real]; at a slot each position is tried against
 * the Set for 1..[maxNameTokens] words. The cost is about slots × positions
 * × maxNameTokens lookups, whatever the graph holds; nothing backtracks and
 * a slot never takes free text. Malformed spans (overlapping, out of range,
 * more than [maxSlots]) fail closed.
 */
export function sameLineButNames(written, spans, real, names) {
  const w = tokenize(written);
  const r = tokenize(real);
  const rl = lower(r);
  if (!Array.isArray(spans) || spans.length > maxSlots) return false;
  const slotAt = new Map();
  let last = 0;
  for (const span of spans) {
    const [start, end] = Array.isArray(span) ? span : [];
    if (!Number.isInteger(start) || !Number.isInteger(end)) return false;
    if (start < last || end <= start || end > w.length) return false;
    slotAt.set(start, end);
    last = end;
  }
  let at = new Set([0]);
  for (let i = 0; i < w.length && at.size > 0; ) {
    const next = new Set();
    const end = slotAt.get(i);
    if (end !== undefined) {
      for (const p of at) {
        let key = "";
        for (let len = 1; len <= maxNameTokens && p + len <= rl.length; len += 1) {
          key = len === 1 ? rl[p] : `${key} ${rl[p + len - 1]}`;
          if (names.has(key)) next.add(p + len);
        }
      }
      i = end;
    } else {
      for (const p of at) if (r[p] === w[i]) next.add(p + 1);
      i += 1;
    }
    at = next;
  }
  return at.has(r.length);
}

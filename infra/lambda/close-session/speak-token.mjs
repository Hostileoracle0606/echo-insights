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

const lower = (tokens) => tokens.map((t) => t.toLocaleLowerCase("und"));

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
  for (let i = 0; i < tokens.length; ) {
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

/**
 * True when [real] is [written] with each slot (a stand-in's span) replaced
 * by one of [names] (the user's own entity names and aliases, read with
 * their token), compared case-insensitively, and every other token
 * identical. Runs as a set of reachable positions in [real], one step per
 * written token: linear in the line times the names that share a first
 * word, never backtracking, never free text in a slot.
 */
export function sameLineButNames(written, spans, real, names) {
  const w = tokenize(written);
  const r = tokenize(real);
  const rl = lower(r);
  const byFirst = new Map();
  for (const name of names) {
    const t = lower(tokenize(name));
    if (t.length === 0 || t.length > r.length) continue;
    const list = byFirst.get(t[0]) ?? [];
    list.push(t);
    byFirst.set(t[0], list);
  }
  const slotAt = new Map(spans.map(([start, end]) => [start, end]));
  let at = new Set([0]);
  for (let i = 0; i < w.length && at.size > 0; ) {
    const next = new Set();
    const end = slotAt.get(i);
    if (end !== undefined) {
      for (const p of at) {
        for (const name of byFirst.get(rl[p]) ?? []) {
          if (name.every((t, k) => rl[p + k] === t)) next.add(p + name.length);
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

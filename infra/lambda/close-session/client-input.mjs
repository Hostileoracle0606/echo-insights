// Request bodies that carry the conversation from the app (LM-56, ruling R24).
//
// From v2 the iOS app sends the text the model reads: the transcript, and for
// the brief the memory lists, with every name it knows swapped on the device
// for a stand-in. The Lambda uses that text instead of reading
// conversation_turns, so the real names never reach Gemini, and hands the
// result back unsaved: the app swaps the names back and saves it through the
// same RPC as before. A request with no version (every older app) keeps the
// v1 path, which reads the database and saves.
//
// Everything here is untrusted input from a signed-in caller. Shapes and
// sizes are checked before anything else runs. The caps are about 1.25 times
// what the database itself accepts (conversation_turns.text, LM-46's RPC
// caps): the text arrives with names swapped, and a stand-in can be longer
// than the name it replaced, which must not turn into a permanent 400. The
// app clamps to these same numbers (lib/services/model_inputs.dart).

import { createHash } from "node:crypto";

export const inputLimits = Object.freeze({
  turns: 1000,
  // conversation_turns.text is 1..20000 characters.
  turnText: 25_000,
  // All turn text together. The model reads the last 24 000 characters
  // (validate.mjs limits.transcriptChars); the app sends a little more.
  totalTurnChars: 125_000,
  spokenAt: 40,
  entities: 500,
  entityName: 250,
  // The brief's lists, as the v1 path reads them from the database.
  followUps: 10,
  followUpText: 1250,
  questionEntities: 10,
  questionsPerEntity: 20,
  questionText: 625,
  topEntities: 15,
  // save_session_brief's caps (LM-46), plus headroom.
  focusItems: 10,
  focusText: 625,
  openingThread: 1250,
  // The real line the app swapped back. The runtime clamps what it speaks
  // to save_session_brief's 160 and hands that back for the save.
  openingLine: 200,
});

const entityTypes = new Set([
  "person",
  "place",
  "organization",
  "project",
  "event",
  "activity",
  "concept",
  "emotion",
  "other",
]);

/**
 * How the app names an entity in a v2 body: never by its id, which is the
 * real name's slug, but by a namespaced hash, sha256("<notebookId>:<id>") in
 * hex. The runtime computes the same for the notebook's entities to match
 * them up. Not secret: someone who suspects a name can hash a guess.
 */
export function entityKey(notebookId, entityId) {
  return createHash("sha256").update(`${notebookId}:${entityId}`).digest("hex");
}

const entityKeyPattern = /^[0-9a-f]{64}$/;

const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

const boundedString = (value, max, { allowEmpty = false } = {}) =>
  typeof value === "string" && value.length <= max && (allowEmpty || value.trim().length > 0);

const revision = (value) => Number.isSafeInteger(value) && value >= 0;

/**
 * The parsed JSON body: an object, or {} when there is none or it isn't
 * JSON (v1 treated an unreadable body as a plain final close; that stays).
 */
export function readBody(event) {
  let body = event?.body;
  if (typeof body !== "string" || body.length === 0) return {};
  try {
    if (event.isBase64Encoded) body = Buffer.from(body, "base64").toString("utf8");
    const parsed = JSON.parse(body);
    return isObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/** Turns in conversation order, as { speaker, text, spoken_at? }, or null. */
function parseTurns(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > inputLimits.turns) return null;
  let total = 0;
  const turns = [];
  for (const turn of value) {
    if (!isObject(turn)) return null;
    if (turn.speaker !== "user" && turn.speaker !== "assistant") return null;
    if (!boundedString(turn.text, inputLimits.turnText)) return null;
    total += turn.text.length;
    if (total > inputLimits.totalTurnChars) return null;
    const parsed = { speaker: turn.speaker, text: turn.text };
    if (turn.spokenAt != null) {
      if (
        !boundedString(turn.spokenAt, inputLimits.spokenAt) ||
        Number.isNaN(Date.parse(turn.spokenAt))
      ) {
        return null;
      }
      parsed.spoken_at = turn.spokenAt;
    }
    turns.push(parsed);
  }
  return turns;
}

function parseStrings(value, maxItems, maxLength) {
  if (!Array.isArray(value) || value.length > maxItems) return null;
  return value.every((item) => boundedString(item, maxLength)) ? [...value] : null;
}

/**
 * POST /close, v2: { version: 2, draft?, turns, entities, sourceRevision? }.
 * `entities` is [{ key, name }]: see [entityKey].
 * Returns { version: 1, draft } for an older app, the parsed v2 request, or
 * null when a v2 body is malformed or too large.
 */
export function parseCloseRequest(body) {
  if (body.version == null) return { version: 1, draft: body.draft === true };
  if (body.version !== 2) return null;
  if (body.draft != null && typeof body.draft !== "boolean") return null;
  const turns = parseTurns(body.turns);
  if (!turns) return null;
  const entities = body.entities ?? [];
  if (!Array.isArray(entities) || entities.length > inputLimits.entities) return null;
  const names = new Map();
  for (const entity of entities) {
    if (!isObject(entity)) return null;
    if (typeof entity.key !== "string" || !entityKeyPattern.test(entity.key)) return null;
    if (!boundedString(entity.name, inputLimits.entityName)) return null;
    names.set(entity.key, entity.name.trim());
  }
  if (body.sourceRevision != null && !revision(body.sourceRevision)) return null;
  return {
    version: 2,
    draft: body.draft === true,
    turns,
    names,
    sourceRevision: body.sourceRevision ?? null,
  };
}

/**
 * POST /brief, v2. Two shapes:
 * - write: { version: 2, turns, previous, followUps, questions, topEntities,
 *   sourceRevision? } returns the brief text, unsaved;
 * - speak: { version: 2, speak: { openingLine, speakToken } } returns the
 *   audio for the line the app has swapped the names back into. The token
 *   comes from the write (see speak-token.mjs).
 * Returns { version: 1 } for an older app, the parsed request, or null.
 */
export function parseBriefRequest(body) {
  if (body.version == null) return { version: 1 };
  if (body.version !== 2) return null;

  if (body.speak != null) {
    const speak = body.speak;
    if (!isObject(speak)) return null;
    if (!boundedString(speak.openingLine, inputLimits.openingLine)) return null;
    if (!boundedString(speak.speakToken, 2000)) return null;
    return {
      version: 2,
      kind: "speak",
      openingLine: speak.openingLine.trim(),
      speakToken: speak.speakToken,
    };
  }

  const turns = parseTurns(body.turns);
  if (!turns) return null;

  let previous = null;
  if (body.previous != null) {
    if (!isObject(body.previous)) return null;
    const focus = parseStrings(body.previous.focus ?? [], inputLimits.focusItems, inputLimits.focusText);
    const thread = body.previous.openingThread ?? "";
    if (!focus || !boundedString(thread, inputLimits.openingThread, { allowEmpty: true })) {
      return null;
    }
    previous = { focus, openingThread: thread };
  }

  const followUps = parseStrings(body.followUps ?? [], inputLimits.followUps, inputLimits.followUpText);
  if (!followUps) return null;

  const rawQuestions = body.questions ?? [];
  if (!Array.isArray(rawQuestions) || rawQuestions.length > inputLimits.questionEntities) {
    return null;
  }
  const questions = [];
  for (const item of rawQuestions) {
    if (!isObject(item) || !boundedString(item.name, inputLimits.entityName)) return null;
    const list = parseStrings(item.questions, inputLimits.questionsPerEntity, inputLimits.questionText);
    if (!list || list.length === 0) return null;
    questions.push({ name: item.name, questions: list });
  }

  const rawTop = body.topEntities ?? [];
  if (!Array.isArray(rawTop) || rawTop.length > inputLimits.topEntities) return null;
  const topEntities = [];
  for (const item of rawTop) {
    if (!isObject(item) || !boundedString(item.name, inputLimits.entityName)) return null;
    if (!entityTypes.has(item.type)) return null;
    topEntities.push({ name: item.name, type: item.type });
  }

  if (body.sourceRevision != null && !revision(body.sourceRevision)) return null;
  return {
    version: 2,
    kind: "write",
    turns,
    previous,
    followUps,
    questions,
    topEntities,
    sourceRevision: body.sourceRevision ?? null,
  };
}

/**
 * The revision a card or brief written from the app's transcript is for: the
 * notebook's, unless the app read the transcript at an earlier one. A turn
 * saved after the app read the transcript must not count as covered.
 */
export function effectiveRevision(databaseRevision, clientRevision) {
  const current = Number(databaseRevision);
  return clientRevision == null ? current : Math.min(current, clientRevision);
}

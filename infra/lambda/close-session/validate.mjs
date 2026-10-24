// Shared validation for close-session output (contracts/session-card-v1).
//
// Model output is never trusted as-is: lengths are clamped, notes for ids
// that weren't offered are dropped, names and types come from the snapshot,
// and quotes must be the user's own words. LM-36's generators reuse all of it.

export const limits = Object.freeze({
  title: 60,
  summary: 280,
  notes: 5,
  noteText: 200,
  entityNote: 80,
  remember: 8,
  transcriptChars: 24_000,
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

// Wrapping quotes a model sometimes adds around a title or note.
const wrappingQuotes = /^["'“”‘’«»]+|["'“”‘’«»]+$/g;

/**
 * Collapses whitespace, strips wrapping quotes and clamps to [maxLength]
 * characters (ending with "…" when cut). Returns "" for anything that isn't a
 * string, so callers can treat empty as missing.
 */
export function cleanText(value, maxLength) {
  if (typeof value !== "string") return "";
  const text = value.replace(/\s+/g, " ").trim().replace(wrappingQuotes, "").trim();
  const characters = [...text];
  if (characters.length <= maxLength) return text;
  return `${characters.slice(0, maxLength - 1).join("").trimEnd()}…`;
}

/**
 * The "Lumen will remember" candidates, decided in code: this notebook's
 * entities, most mentioned first, never a suppressed id, at most
 * [limits.remember]. [notebookCounts] maps an entity id to
 * user_entities.notebook_count; 1 means only this conversation mentions it.
 */
export function rememberCandidates(snapshot, notebookCounts = new Map(), max = limits.remember) {
  const suppressed = new Set(
    Array.isArray(snapshot?.suppressedEntityIds) ? snapshot.suppressedEntityIds : [],
  );
  const entities = snapshot?.state?.entities;
  const values = entities && typeof entities === "object" ? Object.values(entities) : [];
  return values
    .filter(
      (entity) =>
        entity &&
        typeof entity.id === "string" &&
        entity.id.length > 0 &&
        typeof entity.name === "string" &&
        entity.name.trim().length > 0 &&
        !suppressed.has(entity.id),
    )
    .sort(
      (a, b) =>
        (Number(b.mentions) || 0) - (Number(a.mentions) || 0) ||
        String(b.lastSeen ?? "").localeCompare(String(a.lastSeen ?? "")) ||
        a.id.localeCompare(b.id),
    )
    .slice(0, max)
    .map((entity) => ({
      entityId: entity.id,
      name: entity.name.trim(),
      type: entityTypes.has(entity.type) ? entity.type : "other",
      isNew: notebookCounts.get(entity.id) === 1,
    }));
}

/**
 * Validates write_session_card arguments for a Just talk card. Returns
 * { title, summary, notes, entityNotes } or null when a required part is
 * missing after cleaning. entityNotes is a Map holding only candidate ids.
 */
export function justTalkFromModel(args, candidates) {
  if (!args || typeof args !== "object" || Array.isArray(args)) return null;
  const title = cleanText(args.title, limits.title).replace(/[.。]+$/, "").trim();
  const summary = cleanText(args.summary, limits.summary);
  const notes = (Array.isArray(args.notes) ? args.notes : [])
    .map((note) => cleanText(note, limits.noteText))
    .filter((note) => note.length > 0)
    .slice(0, limits.notes);
  if (!title || !summary || notes.length === 0) return null;

  const candidateIds = new Set(candidates.map((item) => item.entityId));
  const entityNotes = new Map();
  for (const item of Array.isArray(args.entityNotes) ? args.entityNotes : []) {
    if (!item || typeof item !== "object") continue;
    if (!candidateIds.has(item.entityId) || entityNotes.has(item.entityId)) continue;
    const note = cleanText(item.note, limits.entityNote);
    if (note) entityNotes.set(item.entityId, note);
  }
  return { title, summary, notes, entityNotes };
}

/** The remember list in candidate order: names and types from the snapshot. */
export function rememberItems(candidates, entityNotes = new Map()) {
  return candidates.map((item) => ({
    entityId: item.entityId,
    name: item.name,
    type: item.type,
    note: entityNotes.get(item.entityId) ?? null,
    isNew: item.isNew,
  }));
}

/**
 * Drops every quote that isn't a verbatim substring of one of the user's own
 * turns (Lumen's turns never count). Looks at card.quotes and at each
 * card.topics[].quotes, the places session-card v1 carries quotes. Returns a
 * new card; the input is not changed.
 */
export function validateQuotes(card, userTurns) {
  const texts = (Array.isArray(userTurns) ? userTurns : [])
    .map((turn) => (typeof turn === "string" ? turn : turn?.text))
    .filter((text) => typeof text === "string" && text.length > 0);
  const verbatim = (quote) => {
    const text = typeof quote?.text === "string" ? quote.text.trim() : "";
    return text.length > 0 && texts.some((turn) => turn.includes(text));
  };
  const keep = (quotes) =>
    quotes
      .filter(verbatim)
      .map((quote) => ({ ...quote, text: quote.text.trim() }));

  const next = { ...card };
  if (Array.isArray(card?.quotes)) next.quotes = keep(card.quotes);
  if (Array.isArray(card?.topics)) {
    next.topics = card.topics.map((topic) =>
      topic && Array.isArray(topic.quotes) ? { ...topic, quotes: keep(topic.quotes) } : topic,
    );
  }
  return next;
}

/**
 * The transcript the model reads: oldest first, each turn labelled You or
 * Lumen, trimmed from the front to the last [maxChars] characters.
 */
export function buildTranscript(turns, maxChars = limits.transcriptChars) {
  const lines = turns
    .filter((turn) => typeof turn?.text === "string" && turn.text.trim().length > 0)
    .map((turn) => `${turn.speaker === "user" ? "You" : "Lumen"}: ${turn.text.trim()}`);
  const kept = [];
  let total = 0;
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const cost = lines[index].length + (kept.length > 0 ? 1 : 0);
    if (total + cost > maxChars) {
      // The newest turn alone is too long: keep its end.
      if (kept.length === 0) kept.unshift(`…${lines[index].slice(-(maxChars - 1))}`);
      return { text: kept.join("\n"), trimmed: true, turnCount: kept.length };
    }
    kept.unshift(lines[index]);
    total += cost;
  }
  return { text: kept.join("\n"), trimmed: false, turnCount: kept.length };
}

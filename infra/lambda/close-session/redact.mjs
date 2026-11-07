import { Rejection } from "./core.mjs";

// Turn texts are joined by a control character, which is a gap (never part of
// a name) to redact_forgotten, so no name can span two turns. It is taken out
// of the text first: one in a turn would break the split below for good.
const separator = "\u0001";

/**
 * [texts] with every forgotten name replaced by "someone" (LM-49), through
 * one redact_forgotten_text call made with the user's own token. Fails
 * closed: a missing or malformed answer rejects the request rather than
 * sending the original text on.
 */
export async function redactTexts(db, texts) {
  if (texts.length === 0) return texts;
  const clean = texts.map((text) => (typeof text === "string" ? text.replaceAll(separator, "") : ""));
  const redacted = await db.rpc("redact_forgotten_text", { p_text: clean.join(separator) });
  if (typeof redacted !== "string") throw new Rejection(503, "providerUnavailable");
  const parts = redacted.split(separator);
  if (parts.length !== texts.length) throw new Rejection(503, "providerUnavailable");
  return parts;
}

/**
 * The turns with every forgotten name replaced (see [redactTexts]). The model
 * and the quote check then both work from the redacted text. Text the app
 * sent (LM-56) goes through it too: a forgotten name is no longer in the
 * app's name map, so it would otherwise arrive as it was said.
 */
export async function redactTurns(db, turns) {
  if (turns.length === 0) return turns;
  const parts = await redactTexts(
    db,
    turns.map((turn) => turn?.text),
  );
  return turns.map((turn, index) => ({ ...turn, text: parts[index] }));
}

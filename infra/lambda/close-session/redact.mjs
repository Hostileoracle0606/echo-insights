import { Rejection } from "./core.mjs";

// Turn texts are joined by a control character, which is a gap (never part of
// a name) to redact_forgotten, so no name can span two turns. It is taken out
// of the text first: one in a turn would break the split below for good.
const separator = "\u0001";

/**
 * The turns with every forgotten name replaced by "someone" (LM-49), through
 * one redact_forgotten_text call made with the user's own token. The model
 * and the quote check then both work from the redacted text. Fails closed: a
 * missing or malformed answer rejects the close rather than sending the
 * original text on.
 */
export async function redactTurns(db, turns) {
  if (turns.length === 0) return turns;
  const texts = turns.map((turn) =>
    typeof turn?.text === "string" ? turn.text.replaceAll(separator, "") : "",
  );
  const redacted = await db.rpc("redact_forgotten_text", { p_text: texts.join(separator) });
  if (typeof redacted !== "string") throw new Rejection(503, "providerUnavailable");
  const parts = redacted.split(separator);
  if (parts.length !== turns.length) throw new Rejection(503, "providerUnavailable");
  return turns.map((turn, index) => ({ ...turn, text: parts[index] }));
}

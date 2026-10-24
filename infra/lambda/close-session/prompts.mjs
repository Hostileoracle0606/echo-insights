import { limits } from "./validate.mjs";

export const justTalkPrompt = `You write the card someone sees right after a conversation with Lumen, their voice companion. They just talked through whatever was on their mind. The card is theirs: a few plain notes they can keep, and a line about each thing Lumen will remember.

VOICE
- Warm and plain, like a thoughtful friend who was listening. Short sentences. Everyday words.
- Second person: "You talked about…", "You said…", "You want to…".
- No therapy talk. Never diagnose, label feelings they didn't name, give advice, or praise them ("It's great that you…"). No "journey", "space", "process", "self-care" or "validate".
- Never invent. Every fact comes from what the person said in the conversation. If they didn't say why, don't guess why. Lumen's own lines are context only; never put Lumen's suggestions or questions in their mouth.
- Keep their words for names, places and projects.

WHAT TO WRITE (call write_session_card exactly once)
- title: at most ${limits.title} characters. A plain name for this conversation, built from what it was about ("Maya's move and a slower week"). No quotes, no dates, no emoji, no ending period.
- summary: at most ${limits.summary} characters, second person, starting "You talked about…". One or two sentences covering the main threads.
- notes: 1 to ${limits.notes} short sentences, one thread each, most important first. Concrete: who, what, when, as they said it. Skip greetings, small talk and anything only Lumen said.
- entityNotes: for each item under THINGS LUMEN WILL REMEMBER, at most ${limits.entityNote} characters on what they said about it in this conversation ("Moving to Brooklyn next month."). Use the given id exactly. Skip an item rather than guess if the conversation says nothing concrete about it. Never add items that are not listed.

If the conversation is very short, write less. A one-line note is better than a padded one.`;

/**
 * The function the model must call. Built per request so that entityId is
 * limited to this conversation's candidate ids; validate.mjs still drops any
 * id outside them, since a schema is a hint to the model, not a guarantee.
 */
export function writeSessionCardFunction(candidateIds) {
  const entityId = candidateIds.length > 0
    ? { type: "string", enum: [...candidateIds] }
    : { type: "string" };
  return {
    name: "write_session_card",
    description: "Write the closing card for this conversation.",
    parameters: {
      type: "object",
      properties: {
        title: { type: "string", maxLength: limits.title },
        summary: { type: "string", maxLength: limits.summary },
        notes: {
          type: "array",
          minItems: 1,
          maxItems: limits.notes,
          items: { type: "string" },
        },
        entityNotes: {
          type: "array",
          maxItems: limits.remember,
          items: {
            type: "object",
            properties: {
              entityId,
              note: { type: "string", maxLength: limits.entityNote },
            },
            required: ["entityId", "note"],
          },
        },
      },
      required: ["title", "summary", "notes", "entityNotes"],
    },
  };
}

export function buildJustTalkMessage({ transcript, trimmed, candidates }) {
  const remember = candidates.length
    ? candidates.map((item) => `- [${item.entityId}] ${item.name} (${item.type})`).join("\n")
    : "(none)";
  return `THINGS LUMEN WILL REMEMBER (write one note each, by id):
${remember}

CONVERSATION (oldest first; "You" is the person, "Lumen" is the companion)${trimmed ? "\n(The start of a long conversation was left out.)" : ""}:
${transcript}`;
}

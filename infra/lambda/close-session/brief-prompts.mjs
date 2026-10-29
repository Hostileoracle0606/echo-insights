import { cleanText } from "./validate.mjs";

export const briefLimits = Object.freeze({
  focusItems: 4,
  focus: 140,
  openingThread: 200,
  openingLine: 160,
});

export const briefPrompt = `You prepare how Lumen, a voice companion, will open its next conversation with this person. You write a short brief for Lumen and the exact words Lumen will say first. The words are spoken aloud in Lumen's voice, the moment the person starts a new conversation.

THE OPENING LINE (openingLine, at most ${briefLimits.openingLine} characters)
- A warm hello, then one question about one specific thing. One or two sentences, easy to say aloud. Like a friend catching up: "Hey, good to hear from you. Did the demo go the way you hoped?"
- Ask one question only. Never two, never a list.
- Not a recap of the last conversation. Never introduce Lumen ("I'm Lumen"). Never sound like a database: no "I remember", "you told me", "according to my notes", "last time you said".
- Choose the thread in this order: something left open (an unanswered question, a plan with a day or a deadline, something they said they would do or wanted to tell you about); then the most relevant recent thread from their life.
- It will be heard some time from now, not today. Write it for "the next time we talk": never a calendar date, and avoid "today", "tonight" or "yesterday". A day name is fine only when the question still reads sensibly later ("Did the demo go well?" is better than "Is the demo tomorrow?").
- A painful topic (loss, illness, conflict, anything they were clearly upset about) never opens the conversation, unless the person framed it as something to follow up on ("I'll tell you how the scan goes"). Then ask gently and openly. If no thread is safe, use a warm greeting with no specific question: "Hey, good to see you. How are you doing?"

WHAT TO WRITE (call write_session_brief exactly once)
- focus: 1 to ${briefLimits.focusItems} short lines, each at most ${briefLimits.focus} characters, on what matters most to this person right now across everything below, not only the last conversation. Plain facts in their words. Carry open plans and unresolved things forward from the previous brief until the conversation shows they are settled.
- openingThread: at most ${briefLimits.openingThread} characters. The one thread the opening line asks about and why it is worth asking, so Lumen can follow up naturally after the person answers. If no thread is safe and the opening line is a warm greeting with no specific question, leave openingThread empty (""). Never invent a thread to fill it.
- openingLine: as above.

Never invent. Every fact comes from what the person said, the previous brief, or the memory lists. Lumen's own lines are context only; never turn Lumen's suggestions into the person's plans. If little was said, write less.`;

export function writeSessionBriefFunction() {
  return {
    name: "write_session_brief",
    description: "Write the brief and the opening line for the next conversation.",
    parameters: {
      type: "object",
      properties: {
        focus: {
          type: "array",
          minItems: 1,
          maxItems: briefLimits.focusItems,
          items: { type: "string", maxLength: briefLimits.focus },
        },
        openingThread: {
          type: "string",
          maxLength: briefLimits.openingThread,
          description:
            'The thread the opening line asks about, and why. Empty ("") when the line asks nothing specific.',
        },
        openingLine: { type: "string", maxLength: briefLimits.openingLine },
      },
      required: ["focus", "openingThread", "openingLine"],
    },
  };
}

/**
 * The model's arguments, cleaned and bounded, or null when anything the
 * opener needs is missing (no focus line, or no opening line). Nothing is
 * saved for a null. An empty openingThread is valid: the "no safe thread"
 * case, where the line is a warm greeting with no specific question.
 */
export function briefFromModel(args) {
  if (!args || typeof args !== "object") return null;
  const focus = (Array.isArray(args.focus) ? args.focus : [])
    .map((item) => cleanText(item, briefLimits.focus))
    .filter(Boolean)
    .slice(0, briefLimits.focusItems);
  const openingThread = cleanText(args.openingThread, briefLimits.openingThread);
  const openingLine = cleanText(args.openingLine, briefLimits.openingLine);
  if (focus.length === 0 || !openingLine) return null;
  return { focus, openingThread, openingLine };
}

const section = (title, lines) => `${title}:\n${lines.length ? lines.join("\n") : "(none)"}`;

export function buildBriefMessage({ transcript, trimmed, previous, followUps, questions, topEntities }) {
  const previousLines = previous
    ? [
        `Opening thread: ${previous.openingThread || "(none: the greeting asked nothing specific)"}`,
        ...(Array.isArray(previous.focus) ? previous.focus.map((item) => `- ${item}`) : []),
      ]
    : [];
  return [
    section("PREVIOUS BRIEF (carry open threads forward until settled)", previousLines),
    section(
      "QUESTIONS LUMEN PLANNED TO ASK, NOT YET ANSWERED",
      followUps.map((item) => `- ${item}`),
    ),
    section(
      "OPEN QUESTIONS ABOUT THINGS IN THEIR LIFE",
      questions.map((item) => `- ${item.name}: ${item.questions.join(" / ")}`),
    ),
    section(
      "MOST MENTIONED PEOPLE AND TOPICS",
      topEntities.map((item) => `- ${item.name} (${item.type})`),
    ),
    `CONVERSATION JUST ENDED (oldest first; "You" is the person, "Lumen" is the companion)${
      trimmed ? "\n(The start of a long conversation was left out.)" : ""
    }:\n${transcript}`,
  ].join("\n\n");
}

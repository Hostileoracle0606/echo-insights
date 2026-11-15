import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { briefPrompt } from "../lambda/close-session/brief-prompts.mjs";
import { forgottenNote as cardNote, justTalkPrompt } from "../lambda/close-session/prompts.mjs";
import { forgottenNote as extractNote, granularPrompt, wikiPrompt } from "../lambda/extract-graph/prompts.mjs";

// LM-63: text reaches these prompts with a forgotten person's name as
// "someone". One neutral line, the same everywhere, naming nobody.
const expected =
  "\"someone\" may stand in for a person the user asked you to forget. Don't ask who it is, guess, or bring them up.";

test("the forgotten-person line is the same in every Lambda prompt", () => {
  assert.equal(cardNote, expected);
  assert.equal(extractNote, expected);
  for (const [name, prompt] of Object.entries({ justTalkPrompt, briefPrompt, wikiPrompt, granularPrompt })) {
    assert.ok(prompt.includes(expected), `${name} carries the line`);
  }
});

test("Lumen's live system instruction carries the same line", async () => {
  const dart = await readFile(new URL("../../lib/logic/conversation_policy.dart", import.meta.url), "utf8");
  assert.ok(dart.includes(expected), "conversation_policy.dart carries the line");
});

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { validate } from "./support/json-schema.mjs";

const contracts = new URL("../../contracts/", import.meta.url);
const schema = JSON.parse(await readFile(new URL("session-card-v1.schema.json", contracts), "utf8"));
const modes = ["just_talk", "weekly_debrief", "session_prep", "first_session", "what_landed"];

async function fixture(mode) {
  return JSON.parse(
    await readFile(new URL(`fixtures/session-card-v1.${mode}.json`, contracts), "utf8"),
  );
}

test("the schema lists every conversation mode and has a fixture for each", () => {
  assert.deepEqual(schema.properties.conversationMode.enum, modes);
  assert.equal(schema.allOf.length, modes.length);
});

for (const mode of modes) {
  test(`the ${mode} fixture satisfies session-card v1`, async () => {
    const card = await fixture(mode);
    assert.equal(card.conversationMode, mode);
    assert.deepEqual(validate(schema, card), []);
  });
}

test("a mode's own fields are required for that mode only", async () => {
  const justTalk = await fixture("just_talk");
  const { notes, ...withoutNotes } = justTalk;
  assert.ok(notes.length > 0);
  assert.match(validate(schema, withoutNotes).join("\n"), /missing notes/);

  const debrief = await fixture("weekly_debrief");
  assert.deepEqual(validate(schema, { ...debrief, notes: undefined }), []);
  assert.match(validate(schema, { ...debrief, wins: undefined }).join("\n"), /wins/);
});

test("the common limits hold", async () => {
  const card = await fixture("just_talk");
  assert.match(validate(schema, { ...card, version: 2 }).join("\n"), /expected 1/);
  assert.match(validate(schema, { ...card, title: "x".repeat(61) }).join("\n"), /too long/);
  assert.match(validate(schema, { ...card, summary: "x".repeat(281) }).join("\n"), /too long/);
  assert.match(
    validate(schema, { ...card, notes: ["1", "2", "3", "4", "5", "6"] }).join("\n"),
    /too many items/,
  );
  const nine = Array.from({ length: 9 }, (_, index) => ({
    ...card.remember[0],
    entityId: `e${index}`,
  }));
  assert.match(validate(schema, { ...card, remember: nine }).join("\n"), /too many items/);
});

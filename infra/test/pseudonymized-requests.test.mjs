// LM-56 (ruling R24): v2 requests carry the app's text with names swapped on
// the device. These tests check the Lambdas use that text instead of the
// database's, hand results back unsaved, keep the forget redaction and the
// ownership check, refuse malformed or oversized bodies, and forward no real
// name to Gemini.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createSessionBriefHandler } from "../lambda/close-session/brief.mjs";
import {
  entityKey,
  inputLimits,
  parseBriefRequest,
  parseCloseRequest,
} from "../lambda/close-session/client-input.mjs";
import { createCloseSessionHandler } from "../lambda/close-session/core.mjs";
import { createExtractGraphHandler } from "../lambda/extract-graph/core.mjs";

const fixture = JSON.parse(
  await readFile(new URL("./fixtures/close-session.just-talk.json", import.meta.url), "utf8"),
);
const notebookId = fixture.notebook.id;
const otherNotebookId = "11111111-2222-4333-8444-555555555555";
const clock = Date.parse("2026-10-23T21:05:00.000Z");

// Every real name in the database fixtures. None may reach Gemini on v2.
const REAL = ["Maya", "maya", "Brooklyn", "brooklyn", "Atlas", "atlas", "Dentist Dana"];
// What the app sends instead.
const stand = { Maya: "Anika", "Project Atlas": "Project Halden", Brooklyn: "Corvale" };

const clone = (value) => structuredClone(value);
const ok = (body) => ({ ok: true, status: 200, json: async () => clone(body) });

const swap = (text) =>
  Object.entries(stand).reduce(
    (out, [real, fake]) => out.replaceAll(real, fake),
    text.replaceAll("Atlas", "Halden"),
  );

const appTurns = fixture.turns.map((turn) => ({
  speaker: turn.speaker,
  text: swap(turn.text),
  spokenAt: turn.spoken_at,
}));
const appEntities = [
  { key: entityKey(notebookId, "maya"), name: "Anika" },
  { key: entityKey(notebookId, "project_atlas"), name: "Project Halden" },
  { key: entityKey(notebookId, "running"), name: "running" },
  { key: entityKey(notebookId, "brooklyn"), name: "Corvale" },
];

function event(body, overrides = {}) {
  return {
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-123" } } },
    body: body === undefined ? null : JSON.stringify(body),
    ...overrides,
  };
}

const parse = (response) => JSON.parse(response.body);

/** Fake Supabase (full of real names) and Gemini behind one fetch. */
function world(overrides = {}) {
  const state = {
    notebook: { ...clone(fixture.notebook), ended_at: "2026-10-23T21:02:00.000Z" },
    storedCard: null,
    storedBrief: null,
    forgotten: [],
    calls: [],
    providerBodies: [],
    tables: [],
    saves: [],
    redactions: [],
    ...overrides.state,
  };
  const fetchImpl = async (input, init = {}) => {
    const url = new URL(String(input));
    const body = init.body ? JSON.parse(init.body) : null;
    state.calls.push({ url, body });
    if (url.hostname === "generativelanguage.googleapis.com") {
      state.providerBodies.push(init.body);
      if (url.pathname.includes("tts")) {
        return ok({
          candidates: [
            { content: { parts: [{ inlineData: { data: "UENN", mimeType: "audio/L16;rate=24000" } }] } },
          ],
        });
      }
      if (JSON.stringify(body).includes("write_session_brief")) {
        return ok({
          candidates: [
            {
              content: {
                parts: [
                  {
                    functionCall: {
                      name: "write_session_brief",
                      args: {
                        focus: ["Anika is moving to Corvale"],
                        openingThread: "Anika's move",
                        openingLine: "Hey, how is Anika's move going?",
                      },
                    },
                  },
                ],
              },
            },
          ],
        });
      }
      return ok({
        candidates: [
          {
            content: {
              parts: [
                {
                  functionCall: {
                    name: "write_session_card",
                    args: {
                      title: "Anika's move",
                      summary: "You talked about helping Anika move to Corvale.",
                      notes: ["Anika is moving to Corvale next month."],
                      entityNotes: [
                        { entityId: "e1", note: "Moving to Corvale." },
                        { entityId: "maya", note: "a real id the model was never offered" },
                      ],
                    },
                  },
                },
              ],
            },
          },
        ],
      });
    }
    const path = url.pathname;
    state.tables.push(path);
    if (overrides[path]) return overrides[path]({ url, body }, state);
    switch (path) {
      case "/rest/v1/notebooks":
        return ok(state.notebook ? [state.notebook] : []);
      case "/rest/v1/session_cards":
        return ok(state.storedCard ? [state.storedCard] : []);
      case "/rest/v1/session_briefs":
        return ok(state.storedBrief ? [state.storedBrief] : []);
      case "/rest/v1/rpc/get_notebook_snapshot":
        return ok(fixture.snapshot);
      case "/rest/v1/user_entities":
        return ok(fixture.userEntities.map((row) => ({ ...row, name: "Maya", type: "person" })));
      case "/rest/v1/conversation_turns":
        return ok(clone(fixture.turns));
      case "/rest/v1/follow_ups":
        return ok([{ question: "How did the visit with Dentist Dana go?" }]);
      case "/rest/v1/entities":
        return ok([{ name: "Maya", questions: ["When does Maya move?"] }]);
      case "/rest/v1/rpc/redact_forgotten_text":
        state.redactions.push(body.p_text);
        return ok(state.forgotten.reduce((t, name) => t.replaceAll(name, "someone"), body.p_text));
      case "/rest/v1/rpc/save_session_card":
      case "/rest/v1/rpc/save_session_brief":
        state.saves.push(path);
        return ok({ status: "saved", card: body.p_card });
      default:
        throw new Error(`unexpected request ${path}`);
    }
  };
  const common = {
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => "permanent-test-key",
    fetchImpl,
    now: () => clock,
    sleep: async () => {},
    log: () => {},
  };
  return {
    state,
    close: createCloseSessionHandler(common),
    brief: createSessionBriefHandler(common),
  };
}

function assertNoRealName(state) {
  assert.ok(state.providerBodies.length > 0, "Gemini was called");
  for (const raw of state.providerBodies) {
    // The fixed instructions use example names of their own ("Maya's move"),
    // so only what varies per request is checked: the message and the tools.
    const { system_instruction: _fixed, ...rest } = JSON.parse(raw);
    const body = JSON.stringify(rest);
    for (const name of REAL) {
      assert.equal(body.includes(name), false, `"${name}" was forwarded to Gemini`);
    }
  }
}

const closeV2 = (extra = {}) => ({
  version: 2,
  turns: appTurns,
  entities: appEntities,
  ...extra,
});

// ── close-session v2 ─────────────────────────────────────────────────────

test("close v2 writes from the app's transcript and returns the card unsaved", async () => {
  const { state, close } = world();
  const response = await close(event(closeV2()));
  assert.equal(response.statusCode, 200);
  const body = parse(response);
  assert.equal(body.status, "ready");
  assert.equal(body.saved, false);
  assert.equal(body.card.title, "Anika's move");
  assert.equal(body.card.sourceRevision, fixture.notebook.revision);
  assert.equal(state.tables.includes("/rest/v1/conversation_turns"), false);
  assert.deepEqual(state.saves, []);
});

test("close v2 forwards no real name or real-name id to Gemini", async () => {
  const { state, close } = world();
  await close(event(closeV2()));
  assertNoRealName(state);
  const prompt = state.providerBodies[0];
  assert.match(prompt, /\[e1\] Anika \(person\)/);
  assert.equal(prompt.includes("project_atlas"), false);
});

test("close v2 maps the offered aliases back to the real ids", async () => {
  const { close } = world();
  const { card } = parse(await close(event(closeV2())));
  const maya = card.remember.find((item) => item.entityId === "maya");
  assert.equal(maya.note, "Moving to Corvale.");
  // Names in the remember list come from the database, not the model.
  assert.equal(maya.name, "Maya");
  // An id the model was never offered is dropped.
  assert.equal(card.remember.filter((item) => item.note === "a real id the model was never offered").length, 0);
});

test("close v2 leaves a candidate the app sent no name for out of the prompt", async () => {
  const { state, close } = world();
  const { card } = parse(
    await close(
      event(
        closeV2({
          entities: appEntities.filter((e) => e.key !== entityKey(notebookId, "brooklyn")),
        }),
      ),
    ),
  );
  assertNoRealName(state);
  assert.ok(card.remember.some((item) => item.entityId === "brooklyn" && item.note === null));
});

test("close v2 redacts forgotten names in the app's text and names", async () => {
  const { state, close } = world({ state: { forgotten: ["Anika"] } });
  await close(event(closeV2()));
  assert.equal(state.redactions.length, 1);
  assert.equal(state.providerBodies[0].includes("Anika"), false);
  assert.match(state.providerBodies[0], /someone/);
});

test("close v2 never claims a revision past what the app read", async () => {
  const { close } = world();
  const { card } = parse(await close(event(closeV2({ sourceRevision: 5 }))));
  assert.equal(card.sourceRevision, 5);
  const later = parse(await world().close(event(closeV2({ sourceRevision: 99 }))));
  assert.equal(later.card.sourceRevision, fixture.notebook.revision);
});

test("close v2 draft is unsaved too", async () => {
  const { state, close } = world();
  const body = parse(await close(event(closeV2({ draft: true }))));
  assert.equal(body.saved, false);
  assert.deepEqual(state.saves, []);
});

test("close v2 returns a current stored card as saved, with no model call", async () => {
  const stored = { source_revision: fixture.notebook.revision, card: { title: "kept" } };
  const { state, close } = world({ state: { storedCard: stored } });
  const body = parse(await close(event(closeV2())));
  assert.deepEqual(body, { status: "ready", card: { title: "kept" }, saved: true });
  assert.equal(state.providerBodies.length, 0);
});

test("close v1 (no version) still reads the database and saves", async () => {
  const { state, close } = world();
  const body = parse(await close(event(undefined)));
  assert.equal(body.status, "ready");
  assert.equal("saved" in body, false);
  assert.ok(state.tables.includes("/rest/v1/conversation_turns"));
  assert.deepEqual(state.saves, ["/rest/v1/rpc/save_session_card"]);
});

test("close v2 still needs the caller's token and a notebook RLS shows them", async () => {
  const noUser = world();
  assert.equal((await noUser.close(event(closeV2(), { requestContext: {} }))).statusCode, 401);
  const noBearer = world();
  assert.equal((await noBearer.close(event(closeV2(), { headers: {} }))).statusCode, 401);
  assert.equal(noUser.state.calls.length + noBearer.state.calls.length, 0);
  const notTheirs = world({ state: { notebook: null } });
  const response = await notTheirs.close(event(closeV2()));
  assert.equal(response.statusCode, 404);
  assert.equal(notTheirs.state.providerBodies.length, 0);
  const auth = notTheirs.state.calls[0];
  assert.equal(auth.url.pathname, "/rest/v1/notebooks");
});

const tooLong = "x".repeat(inputLimits.turnText + 1);
const badCloseBodies = {
  "unknown version": { version: 3, turns: appTurns },
  "no turns": closeV2({ turns: [] }),
  "turns not a list": closeV2({ turns: "You: hi" }),
  "bad speaker": closeV2({ turns: [{ speaker: "lumen", text: "hi" }] }),
  "empty text": closeV2({ turns: [{ speaker: "user", text: "  " }] }),
  "turn too long": closeV2({ turns: [{ speaker: "user", text: tooLong }] }),
  "too many turns": closeV2({
    turns: Array.from({ length: inputLimits.turns + 1 }, () => ({ speaker: "user", text: "hi" })),
  }),
  "too much text": closeV2({
    turns: Array.from({ length: 6 }, () => ({ speaker: "user", text: "y".repeat(19_000) })),
  }),
  "bad spokenAt": closeV2({ turns: [{ speaker: "user", text: "hi", spokenAt: "soon" }] }),
  "too many entities": closeV2({
    entities: Array.from({ length: inputLimits.entities + 1 }, () => ({
      key: entityKey(notebookId, "a"),
      name: "x",
    })),
  }),
  "entity name too long": closeV2({
    entities: [{ key: entityKey(notebookId, "a"), name: "n".repeat(201) }],
  }),
  "entity sent by its id": closeV2({ entities: [{ id: "maya", name: "Anika" }] }),
  "entity key not a sha-256": closeV2({ entities: [{ key: "maya", name: "Anika" }] }),
  "negative revision": closeV2({ sourceRevision: -1 }),
  "draft not a boolean": closeV2({ draft: "yes" }),
};
for (const [name, body] of Object.entries(badCloseBodies)) {
  test(`close v2 rejects a malformed body before any call: ${name}`, async () => {
    const { state, close } = world();
    const response = await close(event(body));
    assert.equal(response.statusCode, 400);
    assert.deepEqual(parse(response), { status: "rejected", code: "invalidRequest" });
    assert.equal(state.calls.length, 0);
  });
}

test("entityKey matches the app's (test/pseudonymized_calls_test.dart)", () => {
  assert.equal(
    entityKey("nb", "priya"),
    "9902b537b3bde363cd3c707689214fce6f246daceeae93abf99f68ab086bf511",
  );
});

test("parseCloseRequest keeps v1's reading of a body", () => {
  assert.deepEqual(parseCloseRequest({}), { version: 1, draft: false });
  assert.deepEqual(parseCloseRequest({ draft: true }), { version: 1, draft: true });
});

// ── session brief v2 ─────────────────────────────────────────────────────

const briefWrite = (extra = {}) => ({
  version: 2,
  turns: appTurns,
  previous: { focus: ["Anika's move"], openingThread: "" },
  followUps: ["How did the visit with Dentist Jules go?"],
  questions: [{ name: "Anika", questions: ["When does Anika move?"] }],
  topEntities: [{ name: "Anika", type: "person" }],
  ...extra,
});

test("brief v2 write uses only the app's text and returns the brief unsaved", async () => {
  const { state, brief } = world();
  const response = await brief(event(briefWrite()));
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), {
    status: "ready",
    brief: {
      focus: ["Anika is moving to Corvale"],
      openingThread: "Anika's move",
      openingLine: "Hey, how is Anika's move going?",
    },
    sourceRevision: fixture.notebook.revision,
  });
  for (const table of [
    "/rest/v1/conversation_turns",
    "/rest/v1/follow_ups",
    "/rest/v1/entities",
    "/rest/v1/user_entities",
  ]) {
    assert.equal(state.tables.includes(table), false, `${table} was read`);
  }
  assert.equal(state.providerBodies.length, 1, "no TTS call on write");
  assert.deepEqual(state.saves, []);
  assertNoRealName(state);
});

test("brief v2 write redacts forgotten names in every list", async () => {
  const { state, brief } = world({ state: { forgotten: ["Anika"] } });
  await brief(event(briefWrite()));
  assert.equal(state.redactions.length, 1);
  assert.equal(state.providerBodies[0].includes("Anika"), false);
});

test("brief v2 write keeps the unchanged checks", async () => {
  const stored = {
    source_notebook_id: notebookId,
    source_revision: fixture.notebook.revision,
    brief: {},
    created_at: "2026-10-23T21:03:00.000Z",
  };
  const { state, brief } = world({ state: { storedBrief: stored } });
  assert.deepEqual(parse(await brief(event(briefWrite()))), { status: "unchanged" });
  assert.equal(state.providerBodies.length, 0);
  const newer = { ...stored, source_notebook_id: otherNotebookId };
  const late = world({ state: { storedBrief: newer } });
  assert.deepEqual(parse(await late.brief(event(briefWrite()))), { status: "unchanged" });
});

test("brief v2 speak sends Gemini TTS the one line and nothing else", async () => {
  const { state, brief } = world();
  const line = "Hey, how is Maya's move going?";
  const response = await brief(
    event({ version: 2, speak: { openingLine: line, sourceRevision: fixture.notebook.revision } }),
  );
  assert.deepEqual(parse(response), { status: "ready", audioBase64: "UENN", sampleRate: 24000 });
  assert.equal(state.providerBodies.length, 1);
  const tts = JSON.parse(state.providerBodies[0]);
  assert.equal(JSON.stringify(tts.contents).includes(line), true);
  assert.equal(state.providerBodies[0].includes("Brooklyn"), false);
  assert.deepEqual(state.saves, []);
  for (const table of ["/rest/v1/conversation_turns", "/rest/v1/follow_ups"]) {
    assert.equal(state.tables.includes(table), false);
  }
});

test("brief v2 speak re-checks a newer brief before speaking", async () => {
  const stored = {
    source_notebook_id: otherNotebookId,
    source_revision: 1,
    brief: {},
    created_at: "2026-10-23T21:04:00.000Z",
  };
  const { state, brief } = world({ state: { storedBrief: stored } });
  const response = await brief(
    event({ version: 2, speak: { openingLine: "Hey.", sourceRevision: fixture.notebook.revision } }),
  );
  assert.deepEqual(parse(response), { status: "unchanged" });
  assert.equal(state.providerBodies.length, 0);
});

test("brief v2 speak refuses a revision ahead of the notebook, and others' notebooks", async () => {
  const ahead = world();
  const response = await ahead.brief(
    event({ version: 2, speak: { openingLine: "Hey.", sourceRevision: 999 } }),
  );
  assert.equal(response.statusCode, 400);
  assert.equal(ahead.state.providerBodies.length, 0);
  const notTheirs = world({ state: { notebook: null } });
  const missing = await notTheirs.brief(
    event({ version: 2, speak: { openingLine: "Hey.", sourceRevision: 1 } }),
  );
  assert.equal(missing.statusCode, 404);
});

const badBriefBodies = {
  "line too long": { version: 2, speak: { openingLine: "x".repeat(161), sourceRevision: 1 } },
  "empty line": { version: 2, speak: { openingLine: " ", sourceRevision: 1 } },
  "no revision": { version: 2, speak: { openingLine: "Hey." } },
  "no turns": briefWrite({ turns: [] }),
  "too many follow-ups": briefWrite({ followUps: Array.from({ length: 11 }, () => "q") }),
  "too many top entities": briefWrite({
    topEntities: Array.from({ length: 16 }, () => ({ name: "a", type: "person" })),
  }),
  "unknown entity type": briefWrite({ topEntities: [{ name: "a", type: "pet" }] }),
  "question without questions": briefWrite({ questions: [{ name: "a", questions: [] }] }),
  "focus too long": briefWrite({ previous: { focus: ["f".repeat(501)], openingThread: "" } }),
};
for (const [name, body] of Object.entries(badBriefBodies)) {
  test(`brief v2 rejects a malformed body before any call: ${name}`, async () => {
    const { state, brief } = world();
    const response = await brief(event(body));
    assert.equal(response.statusCode, 400);
    assert.equal(state.calls.length, 0);
  });
}

test("parseBriefRequest: no version is v1", () => {
  assert.deepEqual(parseBriefRequest({}), { version: 1 });
});

// ── extract-graph ────────────────────────────────────────────────────────

test("extract-graph forwards only what the request carried", async () => {
  const providerBodies = [];
  const handle = createExtractGraphHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => "permanent-test-key",
    acquireExtraction: async () => ({ status: "acquired" }),
    completeExtraction: async ({ patch }) => ({ status: "completed", patch }),
    newOwnerToken: () => "owner",
    sleep: async () => {},
    fetchImpl: async (input, init = {}) => {
      const url = new URL(String(input));
      if (url.hostname === "generativelanguage.googleapis.com") {
        providerBodies.push(init.body);
        return ok({
          candidates: [
            {
              content: {
                parts: [{ functionCall: { name: "extract_graph", args: { entities: [], relations: [] } } }],
              },
            },
          ],
        });
      }
      // The notebook check; the database is never a source of prompt text.
      return ok([{ id: notebookId, name: "Maya" }]);
    },
  });
  const response = await handle(
    event({
      turnId: "turn-1",
      extractorVersion: "gemini/extract_graph/v2#ps-0123456789ab",
      text: "Anika is moving to Corvale next month.",
      mode: "granular",
      context: {
        entities: [{ id: "anika", name: "Anika", type: "person" }],
        relations: [],
        recentConversation: [{ role: "user", text: "I talked to Anika." }],
        answeringFollowUp: null,
      },
    }),
  );
  assert.equal(response.statusCode, 200);
  assertNoRealName({ providerBodies });
});

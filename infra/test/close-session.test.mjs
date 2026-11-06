import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createCloseSessionHandler } from "../lambda/close-session/core.mjs";
import { redactTurns } from "../lambda/close-session/redact.mjs";
import { justTalkPrompt, writeSessionCardFunction } from "../lambda/close-session/prompts.mjs";
import {
  buildTranscript,
  cleanText,
  justTalkFromModel,
  limits,
  rememberCandidates,
  validateQuotes,
} from "../lambda/close-session/validate.mjs";
import { validate } from "./support/json-schema.mjs";

const fixture = JSON.parse(
  await readFile(new URL("./fixtures/close-session.just-talk.json", import.meta.url), "utf8"),
);
const schema = JSON.parse(
  await readFile(new URL("../../contracts/session-card-v1.schema.json", import.meta.url), "utf8"),
);
const notebookId = fixture.notebook.id;
const clock = Date.parse("2026-10-23T21:05:00.000Z");

const clone = (value) => structuredClone(value);
const ok = (body) => ({ ok: true, status: 200, json: async () => clone(body) });
const status = (code, body = {}) => ({ ok: code >= 200 && code < 300, status: code, json: async () => body });

function requestEvent(overrides = {}) {
  return {
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-123" } } },
    body: null,
    ...overrides,
  };
}

/**
 * A fake Supabase + Gemini behind one fetch. Every override is a function of
 * the parsed request so tests can change one table and keep the rest.
 */
function world(overrides = {}) {
  const state = {
    notebook: clone(fixture.notebook),
    storedCard: null,
    snapshot: clone(fixture.snapshot),
    turns: clone(fixture.turns),
    userEntities: clone(fixture.userEntities),
    modelArgs: clone(fixture.modelArgs),
    calls: [],
    providerBodies: [],
    saves: [],
    logs: [],
    credentialReads: 0,
    ...overrides.state,
  };
  const fetchImpl = async (input, init = {}) => {
    const url = new URL(String(input));
    const call = { url, init, body: init.body ? JSON.parse(init.body) : null };
    state.calls.push(call);
    if (url.hostname === "generativelanguage.googleapis.com") {
      state.providerBodies.push(call.body);
      if (overrides.provider) return overrides.provider(call, state);
      return ok({
        candidates: [
          { content: { parts: [{ functionCall: { name: "write_session_card", args: state.modelArgs } }] } },
        ],
      });
    }
    const path = url.pathname;
    if (overrides[path]) return overrides[path](call, state);
    if (path === "/rest/v1/notebooks") return ok(state.notebook ? [state.notebook] : []);
    if (path === "/rest/v1/session_cards") return ok(state.storedCard ? [state.storedCard] : []);
    if (path === "/rest/v1/rpc/redact_forgotten_text") {
      state.redactions ??= [];
      state.redactions.push(call);
      return ok(redactWith(state.forgotten ?? [], call.body.p_text));
    }
    if (path === "/rest/v1/rpc/get_notebook_snapshot") return ok(state.snapshot);
    if (path === "/rest/v1/conversation_turns") {
      return ok([...state.turns].sort((a, b) => b.spoken_at.localeCompare(a.spoken_at)));
    }
    if (path === "/rest/v1/user_entities") return ok(state.userEntities);
    if (path === "/rest/v1/rpc/save_session_card") {
      state.saves.push(call.body);
      const tooOld = call.body.p_draft
        ? call.body.p_source_revision > state.notebook.revision
        : call.body.p_source_revision !== state.notebook.revision;
      if (tooOld) {
        return ok({ status: "stale", currentRevision: state.notebook.revision });
      }
      state.storedCard = { source_revision: call.body.p_source_revision, card: call.body.p_card };
      return ok({ status: "saved", card: call.body.p_card });
    }
    throw new Error(`unexpected request ${url}`);
  };
  const handle = createCloseSessionHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => {
      state.credentialReads += 1;
      return "permanent-test-key";
    },
    fetchImpl,
    now: () => clock,
    sleep: async () => {},
    log: (fields) => state.logs.push(JSON.stringify(fields)),
    ...overrides.deps,
  });
  return { state, handle };
}


/** Stand-in for redact_forgotten_text: replaces each forgotten name. */
function redactWith(forgotten, text) {
  return forgotten.reduce((out, name) => out.replaceAll(name, "someone"), text);
}

const parse = (response) => JSON.parse(response.body);

// ── authentication and visibility ────────────────────────────────────────

test("401 without the authorizer's user or a bearer token", async () => {
  const { state, handle } = world();
  const noUser = await handle(requestEvent({ requestContext: {} }));
  const noBearer = await handle(requestEvent({ headers: {} }));
  assert.equal(noUser.statusCode, 401);
  assert.equal(noBearer.statusCode, 401);
  assert.equal(state.calls.length, 0);
});

test("400 for a malformed notebook id", async () => {
  const { handle } = world();
  const response = await handle(requestEvent({ pathParameters: { notebookId: "nope" } }));
  assert.equal(response.statusCode, 400);
});

test("404 when RLS hides the notebook", async () => {
  const { state, handle } = world({ state: { notebook: null } });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 404);
  assert.deepEqual(parse(response), { status: "rejected", code: "notFound" });
  assert.equal(state.providerBodies.length, 0);
});

test("every Supabase call is made as the user, never with a service key", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  const supabaseCalls = state.calls.filter((call) => call.url.hostname === "example.supabase.co");
  assert.ok(supabaseCalls.length >= 5);
  for (const call of supabaseCalls) {
    assert.equal(call.init.headers.authorization, "Bearer signed-user-token");
    assert.equal(call.init.headers.apikey, "public-test-key");
  }
});

test("a REST 401 means the user's token is no longer valid", async () => {
  const { handle } = world({ "/rest/v1/notebooks": () => status(401) });
  assert.equal((await handle(requestEvent())).statusCode, 401);
});

// ── the early return ─────────────────────────────────────────────────────

test("a stored card at the notebook's revision returns without a model call", async () => {
  const stored = { version: 1, notebookId, sourceRevision: 7, title: "Stored" };
  const { state, handle } = world({ state: { storedCard: { source_revision: 7, card: stored } } });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "ready", card: stored });
  assert.equal(state.providerBodies.length, 0);
  assert.equal(state.credentialReads, 0);
  assert.equal(state.saves.length, 0);
});

test("calling it twice returns the same card and saves once", async () => {
  const { state, handle } = world();
  const first = parse(await handle(requestEvent()));
  const second = parse(await handle(requestEvent()));
  assert.deepEqual(second, first);
  assert.equal(state.providerBodies.length, 1);
  assert.equal(state.saves.length, 1);
});

test("a stored card from an older revision is regenerated", async () => {
  const { state, handle } = world({
    state: { storedCard: { source_revision: 5, card: { title: "Old" } } },
  });
  const response = await handle(requestEvent());
  assert.equal(parse(response).card.sourceRevision, 7);
  assert.equal(state.providerBodies.length, 1);
});

// ── dispatch ─────────────────────────────────────────────────────────────

for (const mode of ["weekly_debrief", "session_prep", "first_session", "what_landed"]) {
  test(`${mode} returns 501 until LM-36`, async () => {
    const { state, handle } = world({
      state: { notebook: { ...fixture.notebook, conversation_mode: mode } },
    });
    const response = await handle(requestEvent());
    assert.equal(response.statusCode, 501);
    assert.deepEqual(parse(response), { status: "rejected", code: "notImplemented" });
    assert.equal(state.providerBodies.length, 0);
  });
}

// ── the Just talk card ───────────────────────────────────────────────────

test("a Just talk close saves and returns a card that satisfies the contract", async () => {
  const { state, handle } = world();
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  const { status: outcome, card } = parse(response);
  assert.equal(outcome, "ready");
  assert.deepEqual(validate(schema, card), []);
  assert.equal(card.conversationMode, "just_talk");
  assert.equal(card.sourceRevision, 7);
  assert.equal(card.generatedAt, "2026-10-23T21:05:00.000Z");
  assert.equal(card.title, "Maya's move and a slower week", "quotes and the period stripped");
  assert.equal(card.notes.length, 3);

  const [save] = state.saves;
  assert.equal(save.p_notebook_id, notebookId);
  assert.equal(save.p_source_revision, 7);
  assert.equal(save.p_title, card.title);
  assert.equal(save.p_summary, card.summary);
  assert.deepEqual(save.p_card, card);
});

test("the model is asked once, with the function forced and no randomness", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  const [body] = state.providerBodies;
  const geminiCall = state.calls.find((call) => call.url.hostname === "generativelanguage.googleapis.com");
  assert.match(geminiCall.url.pathname, /gemini-2\.5-flash:generateContent$/);
  assert.equal(geminiCall.init.headers["x-goog-api-key"], "permanent-test-key");
  assert.equal(body.system_instruction.parts[0].text, justTalkPrompt);
  assert.deepEqual(body.tool_config.function_calling_config, {
    mode: "ANY",
    allowed_function_names: ["write_session_card"],
  });
  assert.deepEqual(body.generationConfig, { temperature: 0, thinkingConfig: { thinkingBudget: 0 } });
  const message = body.contents[0].parts[0].text;
  assert.match(message, /^You: Honestly it's been a lot\./m);
  assert.match(message, /^Lumen: That's a big move\./m);
  assert.ok(
    message.indexOf("Maya is moving") < message.indexOf("Sunday runs"),
    "transcript is oldest first",
  );
});

test("the remember list: by mentions, at most 8, isNew from notebook_count", async () => {
  const entities = {};
  for (let index = 0; index < 12; index += 1) {
    entities[`e${index}`] = {
      id: `e${index}`,
      name: `Entity ${index}`,
      type: index === 0 ? "made_up" : "concept",
      mentions: index,
      lastSeen: "2026-10-23T21:00:00.000Z",
    };
  }
  const snapshot = {
    ...fixture.snapshot,
    state: { ...fixture.snapshot.state, entities },
  };
  const userEntities = Array.from({ length: 12 }, (_, index) => ({
    id: `e${index}`,
    notebook_count: index % 2 === 0 ? 1 : 3,
  }));
  const { state, handle } = world({
    state: { snapshot, userEntities, modelArgs: { ...fixture.modelArgs, entityNotes: [] } },
  });
  const { card } = parse(await handle(requestEvent()));

  assert.deepEqual(
    card.remember.map((item) => item.entityId),
    ["e11", "e10", "e9", "e8", "e7", "e6", "e5", "e4"],
  );
  assert.deepEqual(
    card.remember.map((item) => item.isNew),
    [false, true, false, true, false, true, false, true],
  );
  assert.ok(card.remember.every((item) => item.note === null));
  const declaration = state.providerBodies[0].tools[0].function_declarations[0];
  assert.deepEqual(
    declaration.parameters.properties.entityNotes.items.properties.entityId.enum,
    ["e11", "e10", "e9", "e8", "e7", "e6", "e5", "e4"],
  );
  const lookup = state.calls.find((call) => call.url.pathname === "/rest/v1/user_entities");
  assert.equal(lookup.url.searchParams.get("select"), "id,notebook_count");
  assert.match(lookup.url.searchParams.get("id"), /^in\.\("e11","e10",/);
});

test("the remember list's names and types come from the snapshot, not the model", async () => {
  const { handle } = world();
  const { card } = parse(await handle(requestEvent()));
  assert.deepEqual(card.remember, [
    {
      entityId: "maya",
      name: "Maya",
      type: "person",
      note: "Moving to Brooklyn next month; you're helping her pack.",
      isNew: false,
    },
    {
      entityId: "project_atlas",
      name: "Project Atlas",
      type: "project",
      note: "Demo on Thursday; the data pipeline is what's left.",
      isNew: false,
    },
    // Equal mentions: the more recently mentioned comes first.
    {
      entityId: "running",
      name: "running",
      type: "activity",
      note: "You want your Sunday runs back after the demo.",
      isNew: true,
    },
    { entityId: "brooklyn", name: "Brooklyn", type: "place", note: null, isNew: true },
  ]);
});

test("notes for unknown ids are dropped and every length is clamped", async () => {
  const { handle } = world({
    state: {
      modelArgs: {
        title: "T".repeat(90),
        summary: "S".repeat(400),
        notes: ["N".repeat(300), "", "two", "three", "four", "five", "six"],
        entityNotes: [
          { entityId: "maya", note: "M".repeat(120) },
          { entityId: "ex_boss", note: "A suppressed id the model made up." },
          { entityId: "someone_else", note: "Not a candidate." },
          { entityId: "maya", note: "A second note for the same id." },
        ],
      },
    },
  });
  const { card } = parse(await handle(requestEvent()));
  assert.equal([...card.title].length, limits.title);
  assert.ok(card.title.endsWith("…"));
  assert.equal([...card.summary].length, limits.summary);
  assert.equal(card.notes.length, limits.notes);
  assert.equal([...card.notes[0]].length, limits.noteText);
  assert.deepEqual(card.notes.slice(1), ["two", "three", "four", "five"]);
  const maya = card.remember.find((item) => item.entityId === "maya");
  assert.equal([...maya.note].length, limits.entityNote);
  assert.ok(!card.remember.some((item) => ["ex_boss", "someone_else"].includes(item.entityId)));
  assert.deepEqual(validate(schema, card), []);
});

test("a missing function call, title or notes is an invalid provider response", async () => {
  for (const modelArgs of [
    null,
    { ...fixture.modelArgs, title: "  " },
    { ...fixture.modelArgs, notes: [] },
    { ...fixture.modelArgs, summary: 4 },
  ]) {
    const { state, handle } = world({
      state: { modelArgs },
      provider: (call, current) =>
        ok({
          candidates: [
            {
              content: {
                parts: current.modelArgs
                  ? [{ functionCall: { name: "write_session_card", args: current.modelArgs } }]
                  : [{ text: "Here is your card!" }],
              },
            },
          ],
        }),
    });
    const response = await handle(requestEvent());
    assert.equal(response.statusCode, 502);
    assert.equal(parse(response).code, "invalidProviderResponse");
    assert.equal(state.saves.length, 0);
  }
});

test("no user turns means no card and no model call", async () => {
  const { state, handle } = world({
    state: { turns: fixture.turns.filter((turn) => turn.speaker === "assistant") },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 422);
  assert.equal(parse(response).code, "nothingToSummarize");
  assert.equal(state.providerBodies.length, 0);
});

test("a notebook auto-forget has trimmed keeps its card: no model call, no save", async () => {
  const card = { title: "Full card from the whole conversation" };
  const { state, handle } = world({
    state: {
      notebook: { ...clone(fixture.notebook), revision: fixture.notebook.revision + 3, transcript_forgotten_at: "2026-11-01T03:15:00.000Z" },
      storedCard: { source_revision: fixture.notebook.revision, card },
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "ready", card });
  assert.equal(state.providerBodies.length, 0);
  assert.equal(state.saves.length, 0);
});

test("a trimmed notebook with no card is nothing to summarize, and never calls the model", async () => {
  const { state, handle } = world({
    state: { notebook: { ...clone(fixture.notebook), transcript_forgotten_at: "2026-11-01T03:15:00.000Z" } },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 422);
  assert.equal(parse(response).code, "nothingToSummarize");
  assert.equal(state.providerBodies.length, 0);
  assert.equal(state.saves.length, 0);
});

test("a trimmed notebook's draft request also leaves the card alone", async () => {
  const card = { title: "Kept" };
  const { state, handle } = world({
    state: {
      notebook: { ...clone(fixture.notebook), transcript_forgotten_at: "2026-11-01T03:15:00.000Z" },
      storedCard: { source_revision: 1, card },
    },
  });
  assert.deepEqual(parse(await handle(draftEvent())), { status: "ready", card });
  assert.equal(state.saves.length, 0);
});

test("a long transcript keeps only its last ~24,000 characters", async () => {
  const turns = Array.from({ length: 60 }, (_, index) => ({
    turn_id: `t${String(index).padStart(2, "0")}`,
    speaker: index % 2 === 0 ? "user" : "assistant",
    text: `turn ${index} ${"x".repeat(1000)}`,
    spoken_at: new Date(Date.UTC(2026, 9, 23, 20, 0, index)).toISOString(),
    input: "voice",
  }));
  const { state, handle } = world({ state: { turns } });
  await handle(requestEvent());
  const message = state.providerBodies[0].contents[0].parts[0].text;
  assert.match(message, /The start of a long conversation was left out/);
  assert.match(message, /turn 59 /);
  assert.doesNotMatch(message, /turn 0 /);
  const transcript = message.slice(message.search(/^(You|Lumen):/m));
  assert.ok(transcript.length <= limits.transcriptChars);
});

// ── provider failures ────────────────────────────────────────────────────

test("429s are retried, then reported as rateLimited", async () => {
  let attempts = 0;
  const { handle } = world({
    provider: () => {
      attempts += 1;
      return status(429);
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 429);
  assert.deepEqual(parse(response), { status: "rejected", code: "rateLimited" });
  assert.equal(attempts, 3);
});

test("a 429 followed by success still produces the card", async () => {
  let attempts = 0;
  const { handle } = world({
    provider: (call, current) => {
      attempts += 1;
      if (attempts === 1) return status(429);
      return ok({
        candidates: [
          { content: { parts: [{ functionCall: { name: "write_session_card", args: current.modelArgs } }] } },
        ],
      });
    },
  });
  assert.equal((await handle(requestEvent())).statusCode, 200);
  assert.equal(attempts, 2);
});

test("provider errors and a missing credential are providerUnavailable", async () => {
  const failing = world({ provider: () => status(500) });
  const failed = await failing.handle(requestEvent());
  assert.equal(failed.statusCode, 503);
  assert.equal(parse(failed).code, "providerUnavailable");

  const noKey = world({ deps: { getPermanentCredential: async () => "  " } });
  assert.equal((await noKey.handle(requestEvent())).statusCode, 503);

  const throwing = world({
    provider: () => {
      throw new Error("socket hang up");
    },
  });
  assert.equal((await throwing.handle(requestEvent())).statusCode, 503);
});

test("no model call starts once too little of the 30 s budget is left", async () => {
  let time = clock;
  const { state, handle } = world({
    deps: { now: () => time },
    "/rest/v1/user_entities": (call, current) => {
      time += 20_000; // a very slow Supabase read
      return ok(current.userEntities);
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 503);
  assert.equal(state.providerBodies.length, 0);
});

// ── stale saves ──────────────────────────────────────────────────────────

test("a stale save retries once from the start, then succeeds", async () => {
  let saves = 0;
  const { state, handle } = world({
    "/rest/v1/rpc/save_session_card": (call, current) => {
      saves += 1;
      if (saves === 1) {
        // A late commit landed while the card was being written.
        current.notebook.revision = 8;
        current.snapshot.revision = 8;
        return ok({ status: "stale", currentRevision: 8 });
      }
      return ok({ status: "saved", card: call.body.p_card });
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.equal(parse(response).card.sourceRevision, 8);
  assert.equal(state.providerBodies.length, 2);
});

test("still stale after one retry returns 409", async () => {
  const { state, handle } = world({
    "/rest/v1/rpc/save_session_card": () => ok({ status: "stale", currentRevision: 99 }),
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 409);
  assert.deepEqual(parse(response), { status: "rejected", code: "stale" });
  assert.equal(state.providerBodies.length, 2);
});

test("a save the RPC can't find is a 404", async () => {
  const { handle } = world({
    "/rest/v1/rpc/save_session_card": () => ok({ status: "rejected", code: "notFound" }),
  });
  assert.equal((await handle(requestEvent())).statusCode, 404);
});

// ── logging ──────────────────────────────────────────────────────────────

test("logs carry ids, counts and latency, never what was said or written", async () => {
  const forbidden = [
    ...fixture.turns.map((turn) => turn.text),
    fixture.modelArgs.summary,
    "Maya's move",
    ...fixture.modelArgs.notes,
    ...fixture.modelArgs.entityNotes.map((item) => item.note),
    "Maya",
    "Brooklyn",
    "Sunday",
  ];
  const outcomes = [
    world(),
    world({ provider: () => status(500) }),
    world({ "/rest/v1/rpc/save_session_card": () => ok({ status: "stale", currentRevision: 9 }) }),
  ];
  for (const { state, handle } of outcomes) {
    await handle(requestEvent());
    assert.equal(state.logs.length, 1);
    const line = state.logs[0];
    for (const text of forbidden) {
      assert.ok(!line.includes(text), `log leaked ${JSON.stringify(text.slice(0, 30))}`);
    }
    const fields = JSON.parse(line);
    assert.equal(fields.notebookId, notebookId);
    assert.equal(typeof fields.latencyMs, "number");
  }
  const success = JSON.parse(outcomes[0].state.logs[0]);
  assert.equal(success.statusCode, 200);
  assert.equal(success.turns, 7);
  assert.equal(success.userTurns, 3);
  assert.equal(success.candidates, 4);
  assert.equal(success.modelCalls, 1);
});

// ── the shared validator ─────────────────────────────────────────────────

test("validateQuotes keeps verbatim user substrings and drops everything else", () => {
  const userTurns = [
    { speaker: "user", text: "I found out from Priya, not from my own manager. It stung." },
    { speaker: "user", text: "I was up at three again the night before the demo." },
  ];
  const card = {
    title: "Prep",
    quotes: [
      { entryId: "a", day: "2026-10-21", text: "I found out from Priya, not from my own manager." },
      { entryId: "b", day: "2026-10-21", text: "I found out from Priya, not my manager." },
    ],
    topics: [
      {
        rank: 1,
        title: "Reorg",
        quotes: [
          { entryId: "c", day: "2026-10-21", text: "  It stung.  " },
          { entryId: "d", day: "2026-10-21", text: "That's a big move." },
          { entryId: "e", day: "2026-10-21", text: "" },
          { entryId: "f", day: "2026-10-21" },
        ],
      },
      {
        rank: 2,
        title: "Sleep",
        quotes: [{ entryId: "g", day: "2026-10-22", text: "up at three again" }],
      },
      { rank: 3, title: "Lead role" },
    ],
  };
  const checked = validateQuotes(card, userTurns);
  assert.deepEqual(checked.quotes.map((quote) => quote.entryId), ["a"]);
  assert.deepEqual(checked.topics[0].quotes, [{ entryId: "c", day: "2026-10-21", text: "It stung." }]);
  assert.deepEqual(checked.topics[1].quotes.map((quote) => quote.entryId), ["g"]);
  assert.deepEqual(checked.topics[2], { rank: 3, title: "Lead role" });
  assert.equal(card.quotes.length, 2, "the input card is not changed");

  assert.deepEqual(validateQuotes({ topics: [{ quotes: [{ text: "x" }] }] }, []).topics[0].quotes, []);
  const justTalk = { notes: ["a"] };
  assert.deepEqual(validateQuotes(justTalk, userTurns), justTalk);
});

test("Lumen's lines never count as the user's words", () => {
  const checked = validateQuotes(
    { quotes: [{ entryId: "a", day: "2026-10-21", text: "That's a big move." }] },
    fixture.turns.filter((turn) => turn.speaker === "user"),
  );
  assert.deepEqual(checked.quotes, []);
});

test("cleanText collapses, unquotes and clamps", () => {
  assert.equal(cleanText("  “A  title”  ", 60), "A title");
  assert.equal(cleanText(42, 60), "");
  assert.equal(cleanText("abcdef", 4), "abc…");
  assert.equal([...cleanText("😀".repeat(10), 5)].length, 5);
});

test("rememberCandidates tolerates an empty or odd snapshot", () => {
  assert.deepEqual(rememberCandidates(null), []);
  assert.deepEqual(rememberCandidates({ state: { entities: [] } }), []);
  assert.deepEqual(
    rememberCandidates({ state: { entities: { x: { id: "x", name: " ", mentions: 9 } } } }),
    [],
  );
});

test("justTalkFromModel ignores ids outside the candidates", () => {
  const fields = justTalkFromModel(
    { title: "T", summary: "S", notes: ["n"], entityNotes: [{ entityId: "zz", note: "x" }] },
    [{ entityId: "maya" }],
  );
  assert.equal(fields.entityNotes.size, 0);
});

test("buildTranscript keeps the end of a single over-long turn", () => {
  const { text, trimmed } = buildTranscript(
    [{ speaker: "user", text: `${"a".repeat(100)}END` }],
    50,
  );
  assert.ok(trimmed);
  assert.equal(text.length, 50);
  assert.ok(text.endsWith("END"));
});

test("the function declaration has no enum when there are no candidates", () => {
  const declaration = writeSessionCardFunction([]);
  assert.deepEqual(declaration.parameters.properties.entityNotes.items.properties.entityId, {
    type: "string",
  });
  assert.match(justTalkPrompt, /at most 60 characters/);
  assert.match(justTalkPrompt, /at most 280 characters/);
  assert.match(justTalkPrompt, /at most 80 characters/);
});

// ── Drafts: written while the conversation goes on ─────────────────────────

const draftEvent = () => requestEvent({ body: JSON.stringify({ draft: true }) });

test("a draft saves with p_draft from the revision it read, in one pass", async () => {
  const { state, handle } = world();
  state.notebook.revision = Number(state.snapshot.revision) + 1; // the user said more meanwhile
  const response = await handle(draftEvent());
  assert.equal(response.statusCode, 200);
  assert.equal(parse(response).status, "ready");
  assert.equal(state.saves.length, 1);
  assert.equal(state.saves[0].p_draft, true);
  assert.equal(state.saves[0].p_source_revision, Number(state.snapshot.revision));
  assert.equal(state.providerBodies.length, 1);
});

test("a final close sends no p_draft, so the deployed SQL signature still matches", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  assert.equal(state.saves.length, 1);
  assert.equal("p_draft" in state.saves[0], false);
});

test("a draft is marked in the log", async () => {
  const { state, handle } = world();
  await handle(draftEvent());
  assert.equal(JSON.parse(state.logs.at(-1)).draft, true);
});

test("a body that isn't a draft request is a final close", async () => {
  for (const body of ["not json", JSON.stringify({ draft: "yes" }), JSON.stringify([true])]) {
    const { state, handle } = world();
    await handle(requestEvent({ body }));
    assert.equal("p_draft" in state.saves[0], false, body);
  }
});

test("a base64-encoded draft body is read", async () => {
  const { state, handle } = world();
  await handle(
    requestEvent({ body: Buffer.from(JSON.stringify({ draft: true })).toString("base64"), isBase64Encoded: true }),
  );
  assert.equal(state.saves[0].p_draft, true);
});

// ── LM-49: a forgotten name never reaches the model ──────────────────────

test("the transcript is redacted by one user-token call before the model sees it", async () => {
  // The forgotten entity is already gone from the graph.
  const snapshot = clone(fixture.snapshot);
  delete snapshot.state.entities.brooklyn;
  const { state, handle } = world({ state: { forgotten: ["Brooklyn"], snapshot } });
  await handle(requestEvent());
  assert.equal(state.redactions.length, 1);
  assert.equal(state.redactions[0].init.headers.authorization, "Bearer signed-user-token");
  const prompt = JSON.stringify(state.providerBodies[0].contents);
  assert.ok(!prompt.includes("Brooklyn"));
  assert.ok(prompt.includes("someone"));
});

test("a draft is redacted too", async () => {
  const snapshot = clone(fixture.snapshot);
  delete snapshot.state.entities.brooklyn;
  const { state, handle } = world({ state: { forgotten: ["Brooklyn"], snapshot } });
  await handle(requestEvent({ body: JSON.stringify({ draft: true }) }));
  assert.equal(state.redactions.length, 1);
  assert.ok(!JSON.stringify(state.providerBodies[0].contents).includes("Brooklyn"));
});

test("if redaction fails the model is never called", async () => {
  const { state, handle } = world({
    "/rest/v1/rpc/redact_forgotten_text": () => status(500),
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 503);
  assert.equal(state.providerBodies.length, 0);
  assert.equal(state.saves.length, 0);
});

test("a control character in a turn cannot break redaction for good", async () => {
  const turns = [{ text: "a\u0001b" }, { text: "c" }];
  const db = { rpc: async (_name, { p_text }) => p_text };
  const redacted = await redactTurns(db, turns);
  assert.deepEqual(redacted.map((turn) => turn.text), ["ab", "c"]);
});

test("a redaction answer that does not line up with the turns is refused", async () => {
  const { state, handle } = world({
    "/rest/v1/rpc/redact_forgotten_text": () => ok("one blob, no separators"),
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 503);
  assert.equal(state.providerBodies.length, 0);
});

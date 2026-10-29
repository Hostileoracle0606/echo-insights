import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createSessionBriefHandler } from "../lambda/close-session/brief.mjs";
import {
  briefPrompt,
  briefFromModel,
  writeSessionBriefFunction,
} from "../lambda/close-session/brief-prompts.mjs";

const fixture = JSON.parse(
  await readFile(new URL("./fixtures/close-session.just-talk.json", import.meta.url), "utf8"),
);
const notebookId = fixture.notebook.id;
const otherNotebookId = "11111111-2222-4333-8444-555555555555";
const clock = Date.parse("2026-10-23T21:05:00.000Z");
const endedAt = "2026-10-23T21:02:00.000Z";

const clone = (value) => structuredClone(value);
const ok = (body) => ({ ok: true, status: 200, json: async () => clone(body) });
const status = (code, body = {}) => ({ ok: code >= 200 && code < 300, status: code, json: async () => body });

const goodArgs = {
  focus: ["The Atlas demo on Thursday", "Getting Sunday runs back"],
  openingThread: "They said the Atlas demo is on Thursday and wanted to tell how it went.",
  openingLine: "Hey, good to hear from you. Did the Atlas demo go the way you hoped?",
};
const audioBase64 = Buffer.from("pcm-bytes-for-test").toString("base64");

function requestEvent(overrides = {}) {
  return {
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-123" } } },
    body: null,
    ...overrides,
  };
}

/** A fake Supabase + Gemini (text and TTS) behind one fetch. */
function world(overrides = {}) {
  const state = {
    notebook: { ...clone(fixture.notebook), ended_at: endedAt },
    storedBrief: null,
    turns: clone(fixture.turns),
    followUps: [{ question: "How did the dentist visit go?" }],
    questionEntities: [{ name: "Project Atlas", questions: ["Who signs off on the demo?"] }],
    topEntities: [
      { name: "Maya", type: "person", mentions: 9 },
      { name: "Project Atlas", type: "project", mentions: 6 },
    ],
    modelArgs: clone(goodArgs),
    tts: { data: audioBase64, mimeType: "audio/L16;codec=pcm;rate=24000" },
    calls: [],
    providerCalls: [],
    saves: [],
    logs: [],
    ...overrides.state,
  };
  const fetchImpl = async (input, init = {}) => {
    const url = new URL(String(input));
    const call = { url, init, body: init.body ? JSON.parse(init.body) : null };
    state.calls.push(call);
    if (url.hostname === "generativelanguage.googleapis.com") {
      state.providerCalls.push(call);
      if (url.pathname.includes("tts")) {
        const parts = state.tts ? [{ inlineData: state.tts }] : [{ text: "no audio" }];
        return ok({ candidates: [{ content: { parts } }] });
      }
      return ok({
        candidates: [
          { content: { parts: [{ functionCall: { name: "write_session_brief", args: state.modelArgs } }] } },
        ],
      });
    }
    const path = url.pathname;
    if (overrides[path]) return overrides[path](call, state);
    if (path === "/rest/v1/notebooks") return ok(state.notebook ? [state.notebook] : []);
    if (path === "/rest/v1/session_briefs") return ok(state.storedBrief ? [state.storedBrief] : []);
    if (path === "/rest/v1/conversation_turns") {
      return ok([...state.turns].sort((a, b) => b.spoken_at.localeCompare(a.spoken_at)));
    }
    if (path === "/rest/v1/follow_ups") return ok(state.followUps);
    if (path === "/rest/v1/entities") return ok(state.questionEntities);
    if (path === "/rest/v1/user_entities") return ok(state.topEntities);
    if (path === "/rest/v1/rpc/save_session_brief") {
      state.saves.push(call.body);
      return ok({ status: "saved" });
    }
    throw new Error(`unexpected request ${url}`);
  };
  const handle = createSessionBriefHandler({
    supabaseUrl: "https://example.supabase.co",
    publishableKey: "public-test-key",
    getPermanentCredential: async () => "permanent-test-key",
    fetchImpl,
    model: "gemini-2.5-flash",
    ttsModel: "gemini-2.5-flash-preview-tts",
    now: () => clock,
    sleep: async () => {},
    log: (fields) => state.logs.push(JSON.stringify(fields)),
    ...overrides.deps,
  });
  return { state, handle };
}

const parse = (response) => JSON.parse(response.body);
const textCalls = (state) => state.providerCalls.filter((call) => !call.url.pathname.includes("tts"));
const ttsCalls = (state) => state.providerCalls.filter((call) => call.url.pathname.includes("tts"));

test("happy path: one model call, one TTS call, then a save", async () => {
  const { state, handle } = world();
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "ready" });
  assert.equal(textCalls(state).length, 1);
  assert.equal(ttsCalls(state).length, 1);
  const [save] = state.saves;
  assert.equal(save.p_notebook_id, notebookId);
  assert.equal(save.p_source_revision, 7);
  assert.equal(save.p_brief.openingLine, goodArgs.openingLine);
  assert.deepEqual(save.p_brief.focus, goodArgs.focus);
  assert.equal(save.p_brief.openingThread, goodArgs.openingThread);
  assert.equal(save.p_audio_base64, audioBase64);
  assert.equal(save.p_sample_rate, 24000);
});

test("every Supabase call is made as the user", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  const supabaseCalls = state.calls.filter((call) => call.url.hostname === "example.supabase.co");
  assert.ok(supabaseCalls.length >= 6);
  for (const call of supabaseCalls) {
    assert.equal(call.init.headers.authorization, "Bearer signed-user-token");
    assert.equal(call.init.headers.apikey, "public-test-key");
  }
});

test("401 without the authorizer's user, 400 for a bad notebook id, 404 when hidden", async () => {
  const { state, handle } = world();
  assert.equal((await handle(requestEvent({ requestContext: {} }))).statusCode, 401);
  assert.equal((await handle(requestEvent({ headers: {} }))).statusCode, 401);
  assert.equal((await handle(requestEvent({ pathParameters: { notebookId: "nope" } }))).statusCode, 400);
  assert.equal(state.calls.length, 0);
  const hidden = world({ state: { notebook: null } });
  const response = await hidden.handle(requestEvent());
  assert.equal(response.statusCode, 404);
  assert.equal(hidden.state.providerCalls.length, 0);
});

test("a stored brief at the notebook's revision returns without a model call", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: notebookId,
        source_revision: 7,
        brief: goodArgs,
        created_at: "2026-10-23T21:03:00.000Z",
      },
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "unchanged" });
  assert.equal(state.providerCalls.length, 0);
  assert.equal(state.saves.length, 0);
});

test("a stored brief at a later revision of this notebook is also unchanged", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: notebookId,
        source_revision: 9,
        brief: goodArgs,
        created_at: "2026-10-23T21:03:00.000Z",
      },
    },
  });
  assert.deepEqual(parse(await handle(requestEvent())), { status: "unchanged" });
  assert.equal(state.providerCalls.length, 0);
});

test("a stored brief at an older revision of this notebook is rewritten", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: notebookId,
        source_revision: 5,
        brief: goodArgs,
        created_at: "2026-10-23T21:01:00.000Z",
      },
    },
  });
  assert.deepEqual(parse(await handle(requestEvent())), { status: "ready" });
  assert.equal(state.saves.length, 1);
});

test("a brief written after this notebook ended is newer: unchanged, no model call", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: otherNotebookId,
        source_revision: 3,
        brief: goodArgs,
        created_at: "2026-10-23T21:04:00.000Z",
      },
    },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "unchanged" });
  assert.equal(state.providerCalls.length, 0);
  assert.equal(state.saves.length, 0);
});

test("a different notebook's brief written before this one ended is replaced", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: otherNotebookId,
        source_revision: 3,
        brief: goodArgs,
        created_at: "2026-10-23T20:00:00.000Z",
      },
    },
  });
  assert.deepEqual(parse(await handle(requestEvent())), { status: "ready" });
  assert.equal(state.saves.length, 1);
  assert.equal(textCalls(state).length, 1);
});

test("no user turns gives 422 and no model call", async () => {
  const { state, handle } = world({
    state: { turns: fixture.turns.filter((turn) => turn.speaker !== "user") },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 422);
  assert.deepEqual(parse(response), { status: "rejected", code: "nothingToSummarize" });
  assert.equal(state.providerCalls.length, 0);
});

test("weekly_debrief gives 501", async () => {
  const { state, handle } = world({
    state: { notebook: { ...fixture.notebook, conversation_mode: "weekly_debrief", ended_at: endedAt } },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 501);
  assert.deepEqual(parse(response), { status: "rejected", code: "notImplemented" });
  assert.equal(state.providerCalls.length, 0);
});

test("an empty openingLine is an invalid provider response, nothing saved", async () => {
  const { state, handle } = world({ state: { modelArgs: { ...goodArgs, openingLine: "   " } } });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 502);
  assert.deepEqual(parse(response), { status: "rejected", code: "invalidProviderResponse" });
  assert.equal(state.saves.length, 0);
  assert.equal(ttsCalls(state).length, 0);
});

test("no safe thread: a greeting with an empty openingThread is saved", async () => {
  const greeting = { ...goodArgs, openingThread: "", openingLine: "Hey, good to see you. How are you doing?" };
  const { state, handle } = world({ state: { modelArgs: greeting } });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 200);
  assert.deepEqual(parse(response), { status: "ready" });
  assert.equal(ttsCalls(state).length, 1);
  assert.equal(state.saves.length, 1);
  assert.equal(state.saves[0].p_brief.openingThread, "");
  assert.equal(state.saves[0].p_brief.openingLine, greeting.openingLine);
});

test("no safe thread with an empty line is still a 502, nothing saved", async () => {
  const { state, handle } = world({
    state: { modelArgs: { ...goodArgs, openingThread: "", openingLine: "" } },
  });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 502);
  assert.deepEqual(parse(response), { status: "rejected", code: "invalidProviderResponse" });
  assert.equal(state.saves.length, 0);
  assert.equal(ttsCalls(state).length, 0);
});

test("the prompt and schema allow an empty openingThread for no safe thread", () => {
  assert.match(briefPrompt, /leave openingThread empty/);
  assert.match(briefPrompt, /Never invent a thread/);
  const thread = writeSessionBriefFunction().parameters.properties.openingThread;
  assert.equal(thread.minLength, undefined);
  assert.match(thread.description, /Empty \(""\) when the line asks nothing specific/);
});

test("an overlong line is clamped to 160", async () => {
  const { state, handle } = world({
    state: { modelArgs: { ...goodArgs, openingLine: "Hello there. ".repeat(40) } },
  });
  assert.equal((await handle(requestEvent())).statusCode, 200);
  const line = state.saves[0].p_brief.openingLine;
  assert.ok([...line].length <= 160);
  assert.ok([...line].length > 100);
});

test("TTS without audio saves nothing", async () => {
  const { state, handle } = world({ state: { tts: null } });
  const response = await handle(requestEvent());
  assert.equal(response.statusCode, 502);
  assert.deepEqual(parse(response), { status: "rejected", code: "invalidProviderResponse" });
  assert.equal(state.saves.length, 0);
});

test("the sample rate comes from the audio's mime type", async () => {
  const { state, handle } = world({
    state: { tts: { data: audioBase64, mimeType: "audio/L16;codec=pcm;rate=16000" } },
  });
  await handle(requestEvent());
  assert.equal(state.saves[0].p_sample_rate, 16000);
});

test("the save reporting notFound is a 404", async () => {
  const { handle } = world({
    "/rest/v1/rpc/save_session_brief": () => ok({ status: "rejected", code: "notFound" }),
  });
  assert.equal((await handle(requestEvent())).statusCode, 404);
});

test("the save reporting unchanged is passed on", async () => {
  const { handle } = world({
    "/rest/v1/rpc/save_session_brief": () => ok({ status: "unchanged" }),
  });
  assert.deepEqual(parse(await handle(requestEvent())), { status: "unchanged" });
});

test("a failing save is a 503", async () => {
  const { handle } = world({ "/rest/v1/rpc/save_session_brief": () => status(400) });
  assert.equal((await handle(requestEvent())).statusCode, 503);
});

test("the model sees the previous brief, follow-ups, entity questions and top entities", async () => {
  const { state, handle } = world({
    state: {
      storedBrief: {
        source_notebook_id: otherNotebookId,
        source_revision: 3,
        brief: { focus: ["Moving boxes"], openingThread: "PREVIOUS-THREAD-MARKER", openingLine: "x" },
        created_at: "2026-10-20T10:00:00.000Z",
      },
    },
  });
  await handle(requestEvent());
  const message = textCalls(state)[0].body.contents[0].parts[0].text;
  assert.match(message, /PREVIOUS-THREAD-MARKER/);
  assert.match(message, /How did the dentist visit go\?/);
  assert.match(message, /Who signs off on the demo\?/);
  assert.match(message, /Maya/);
  assert.match(message, /Project Atlas/);
  assert.match(message, /^You: Honestly it's been a lot\./m);
});

test("the model call is forced, deterministic, and uses briefPrompt", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  const call = textCalls(state)[0];
  assert.match(call.url.pathname, /gemini-2\.5-flash:generateContent$/);
  assert.equal(call.init.headers["x-goog-api-key"], "permanent-test-key");
  assert.equal(call.body.system_instruction.parts[0].text, briefPrompt);
  assert.deepEqual(call.body.tool_config.function_calling_config, {
    mode: "ANY",
    allowed_function_names: ["write_session_brief"],
  });
  assert.deepEqual(call.body.generationConfig, { temperature: 0, thinkingConfig: { thinkingBudget: 0 } });
});

test("briefPrompt carries the opener copy rules", () => {
  for (const phrase of ["one question", "never", "I remember", "painful", "follow up"]) {
    assert.ok(briefPrompt.includes(phrase), `missing "${phrase}"`);
  }
});

test("every example opening line in briefPrompt has exactly one question", () => {
  const examples = [...briefPrompt.matchAll(/"(Hey[^"]*)"/g)].map((match) => match[1]);
  assert.ok(examples.length >= 2, "expected example opening lines in the prompt");
  for (const example of examples) {
    assert.equal(example.split("?").length - 1, 1, `not exactly one question: ${example}`);
  }
});

test("TTS request: the TTS model, voice Aoede, audio only", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  const call = ttsCalls(state)[0];
  assert.match(call.url.pathname, /gemini-2\.5-flash-preview-tts:generateContent$/);
  assert.equal(
    call.body.contents[0].parts[0].text,
    `Say warmly, unhurried and natural, like a friend catching up: ${goodArgs.openingLine}`,
  );
  assert.deepEqual(call.body.generationConfig.responseModalities, ["AUDIO"]);
  assert.equal(
    call.body.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName,
    "Aoede",
  );
});

test("briefFromModel cleans and bounds the fields", () => {
  assert.equal(briefFromModel(null), null);
  assert.equal(briefFromModel({ ...goodArgs, focus: [] }), null);
  assert.equal(briefFromModel({ ...goodArgs, openingLine: "" }), null);
  assert.equal(briefFromModel({ ...goodArgs, focus: ["  "] }), null);
  assert.deepEqual(briefFromModel({ ...goodArgs, openingThread: "  " }), {
    ...goodArgs,
    openingThread: "",
  });
  const brief = briefFromModel({
    ...goodArgs,
    focus: ["a", "b", "c", "d", "e", "", "x".repeat(300)],
  });
  assert.equal(brief.focus.length, 4);
  const long = briefFromModel({ ...goodArgs, focus: ["x".repeat(300)] });
  assert.ok([...long.focus[0]].length <= 140);
});

test("log lines carry ids and counts, never text", async () => {
  const { state, handle } = world();
  await handle(requestEvent());
  assert.equal(state.logs.length, 1);
  const line = state.logs[0];
  const fields = JSON.parse(line);
  assert.equal(fields.event, "brief");
  assert.equal(fields.notebookId, notebookId);
  assert.equal(fields.statusCode, 200);
  for (const secret of [
    "Atlas",
    "Maya",
    goodArgs.openingLine,
    goodArgs.openingThread,
    goodArgs.focus[0],
    "Honestly",
  ]) {
    assert.ok(!line.includes(secret), `log leaked "${secret}"`);
  }
});

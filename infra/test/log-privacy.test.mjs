// LM-44: no handler may write journal content to its logs, on success or on
// any failure. Every content field below carries MARKER; the test captures
// everything the handler prints and fails if MARKER appears.
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

import { createSessionBriefHandler } from "../lambda/close-session/brief.mjs";
import { createCloseSessionHandler } from "../lambda/close-session/core.mjs";
import { createExtractGraphHandler } from "../lambda/extract-graph/core.mjs";
import { createLiveSessionHandler } from "../lambda/live-session/core.mjs";
import { safeLog, sanitizeLogFields } from "../lambda/close-session/safe-log.mjs";
import { createSupabaseAuthorizer } from "../lambda/supabase-authorizer/core.mjs";

const MARKER = "ZZ-SECRET-MARKER";
const notebookId = "8e03b8f4-4f20-4df3-8398-d854adc32b14";
const fixture = JSON.parse(
  await readFile(new URL("./fixtures/close-session.just-talk.json", import.meta.url), "utf8"),
);

/** Runs `fn` and returns everything it wrote to the console or stdio. */
async function captureOutput(fn) {
  const lines = [];
  const original = {};
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    original[level] = console[level];
    console[level] = (...args) => lines.push(args.map(String).join(" "));
  }
  const stdout = process.stdout.write;
  const stderr = process.stderr.write;
  process.stdout.write = (chunk) => (lines.push(String(chunk)), true);
  process.stderr.write = (chunk) => (lines.push(String(chunk)), true);
  let outcome;
  try {
    outcome = { value: await fn() };
  } catch (error) {
    outcome = { error };
  } finally {
    Object.assign(console, original);
    process.stdout.write = stdout;
    process.stderr.write = stderr;
  }
  return { lines, ...outcome };
}

const ok = (body) => ({ ok: true, status: 200, json: async () => structuredClone(body) });
const failing = (status) => ({
  ok: false,
  status,
  json: async () => ({ error: { message: `${MARKER} provider echoed the prompt` } }),
  text: async () => `${MARKER} provider echoed the prompt`,
});

// An event whose fields throw, to reach code outside every handler's own
// try/catch. The message carries the marker, as a parser error echoing input would.
function explodingEvent() {
  const event = { headers: { authorization: "Bearer signed-user-token" } };
  Object.defineProperty(event, "requestContext", {
    get() {
      throw new SyntaxError(`Unexpected token near ${MARKER}`);
    },
  });
  return event;
}

function userEvent(extra = {}) {
  return {
    headers: { authorization: "Bearer signed-user-token" },
    pathParameters: { notebookId },
    requestContext: { authorizer: { lambda: { userId: "user-123" } } },
    body: null,
    ...extra,
  };
}

const withMarker = (value) => {
  if (typeof value === "string") return `${value} ${MARKER}`;
  if (Array.isArray(value)) return value.map(withMarker);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [
        k,
        k.endsWith("id") ||
        k.endsWith("Id") ||
        k.endsWith("_at") ||
        k === "type" ||
        k === "speaker" ||
        k === "input" ||
        k === "conversation_mode"
          ? v
          : withMarker(v),
      ]),
    );
  }
  return value;
};

/** Supabase tables full of marker text; Gemini behaves per `provider`. */
function leakyFetch(provider) {
  const turns = withMarker(fixture.turns);
  const entities = withMarker(fixture.userEntities);
  return async (input, init = {}) => {
    const url = new URL(String(input));
    if (url.hostname === "generativelanguage.googleapis.com") return provider(url, init);
    switch (url.pathname) {
      case "/rest/v1/notebooks":
        return ok([{ ...fixture.notebook }]);
      case "/rest/v1/conversation_turns":
        return ok(turns);
      case "/rest/v1/user_entities":
      case "/rest/v1/entities":
        return ok(entities);
      case "/rest/v1/rpc/get_notebook_snapshot":
        return ok(withMarker(fixture.snapshot));
      case "/rest/v1/follow_ups":
        return ok([{ id: "f1", question: `Ask about ${MARKER}?`, entity_id: "maya" }]);
      case "/auth/v1/user":
        return ok({ id: "user-123", email: `${MARKER}@example.com` });
      default:
        return ok([]);
    }
  };
}

const providers = {
  modelEchoesContent: () =>
    ok({
      candidates: [
        {
          content: {
            parts: [
              {
                functionCall: {
                  name: "write_session_card",
                  args: withMarker(fixture.modelArgs),
                },
              },
            ],
          },
        },
      ],
    }),
  errorBodyEchoesPrompt: () => failing(500),
  rateLimitedWithBody: () => failing(429),
  networkThrowsWithContent: () => {
    throw new TypeError(`fetch failed while sending ${MARKER}`);
  },
};

const common = {
  supabaseUrl: "https://example.supabase.co",
  publishableKey: "public-test-key",
  getPermanentCredential: async () => "permanent-test-key",
  now: () => Date.parse("2026-10-23T21:05:00.000Z"),
  sleep: async () => {},
};

function closeSession(fetchImpl) {
  return createCloseSessionHandler({ ...common, fetchImpl });
}
function sessionBrief(fetchImpl) {
  return createSessionBriefHandler({ ...common, fetchImpl });
}
function extractGraph(fetchImpl) {
  return createExtractGraphHandler({
    ...common,
    fetchImpl,
    acquireExtraction: async () => ({ status: "acquired" }),
    completeExtraction: async ({ patch }) => ({ status: "completed", patch }),
    newOwnerToken: () => "owner-test",
  });
}
function liveSession(fetchImpl) {
  return createLiveSessionHandler({ ...common, fetchImpl });
}
function authorizer(fetchImpl) {
  return createSupabaseAuthorizer({ ...common, fetchImpl });
}

const extractEvent = () =>
  userEvent({
    body: JSON.stringify({
      turnId: "turn-123",
      extractorVersion: "gemini/extract_graph/v2",
      text: `I talked to ${MARKER} about ${MARKER}`,
      mode: "granular",
      context: {
        entities: [{ id: "maya", name: `${MARKER} Maya`, type: "person" }],
        relations: [],
        recentConversation: [{ speaker: "user", text: `${MARKER} said hello` }],
        answeringFollowUp: null,
      },
    }),
  });

const handlers = {
  "close-session": { make: closeSession, event: userEvent },
  "session-brief": { make: sessionBrief, event: userEvent },
  "extract-graph": { make: extractGraph, event: extractEvent },
  "live-session": { make: liveSession, event: userEvent },
  "supabase-authorizer": { make: authorizer, event: userEvent },
};

for (const [name, { make, event }] of Object.entries(handlers)) {
  for (const [scenario, provider] of Object.entries(providers)) {
    test(`${name} logs no journal content: ${scenario}`, async () => {
      const handle = make(leakyFetch(provider));
      const run = await captureOutput(() => handle(event()));
      assert.equal(run.error, undefined, "handler must answer, not throw");
      assert.equal(run.lines.join("\n").includes(MARKER), false, run.lines.join("\n"));
      assert.equal(
        JSON.stringify(run.value).includes(MARKER),
        false,
        "response must not echo content",
      );
    });
  }

  test(`${name} logs no journal content when an exception escapes`, async () => {
    const handle = make(leakyFetch(providers.modelEchoesContent));
    const run = await captureOutput(() => handle(explodingEvent()));
    assert.equal(run.error, undefined, "an escaped exception must become a plain response");
    assert.equal(run.lines.join("\n").includes(MARKER), false, run.lines.join("\n"));
    assert.equal(JSON.stringify(run.value).includes(MARKER), false);
  });
}

test("the unhandled-exception log names the class and nothing else", async () => {
  const handle = closeSession(leakyFetch(providers.modelEchoesContent));
  const run = await captureOutput(() => handle(explodingEvent()));
  const [line] = run.lines;
  assert.deepEqual(JSON.parse(line), {
    source: "close-session",
    event: "unhandled",
    errorClass: "SyntaxError",
  });
});

test("safeLog keeps ids, counts and codes and drops prose", () => {
  const fields = sanitizeLogFields({
    event: "close",
    notebookId,
    statusCode: 503,
    latencyMs: 12,
    cached: true,
    code: "providerUnavailable",
    summary: `${MARKER} summary`,
    title: MARKER,
    note: { text: MARKER },
    outcome: `${MARKER} has spaces`,
    errorClass: undefined,
  });
  assert.deepEqual(fields, {
    event: "close",
    notebookId,
    statusCode: 503,
    latencyMs: 12,
    cached: true,
    code: "providerUnavailable",
    droppedFields: 4,
  });
  const lines = [];
  safeLog("x", { transcript: MARKER, count: 3 }, (line) => lines.push(line));
  assert.equal(lines.join("").includes(MARKER), false);
});

test("every Lambda directory carries an identical safe-log.mjs", async () => {
  const dirs = (await readdir(new URL("../lambda/", import.meta.url), { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);
  const reference = await readFile(
    new URL("../lambda/close-session/safe-log.mjs", import.meta.url),
    "utf8",
  );
  for (const dir of dirs) {
    const copy = await readFile(new URL(`../lambda/${dir}/safe-log.mjs`, import.meta.url), "utf8");
    assert.equal(copy, reference, `${dir}/safe-log.mjs drifted`);
  }
});

test("no Lambda source prints directly; everything goes through safeLog", async () => {
  const dirs = await readdir(new URL("../lambda/", import.meta.url));
  for (const dir of dirs) {
    for (const file of await readdir(new URL(`../lambda/${dir}/`, import.meta.url))) {
      if (!file.endsWith(".mjs") || file === "safe-log.mjs") continue;
      const source = await readFile(new URL(`../lambda/${dir}/${file}`, import.meta.url), "utf8");
      assert.equal(
        /console\.|process\.std(out|err)/.test(source),
        false,
        `${dir}/${file} prints directly`,
      );
    }
  }
});

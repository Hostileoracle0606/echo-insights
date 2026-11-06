// LM-44: no edge function may write journal content to its logs, on success or
// on any failure. Every content field below carries MARKER; the test captures
// everything the handler prints and fails if MARKER appears.
// Run with the rest of the suite (see docs/guide/testing.md).
import type { DbClient, TableClient } from "./_shared/db-client.ts";
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { StubEmbedder } from "./_shared/embedder.ts";
import { createHandler as embedEntities } from "./embed-entities/handler.ts";
import { createHandler as extractGraph } from "./extract-graph/handler.ts";
import { createHandler as retrieveMemory } from "./retrieve-memory/handler.ts";
import { createHandler as speakAgent } from "./speak-agent/handler.ts";
import { safeLog } from "./_shared/safe-log.ts";

const MARKER = "ZZ-SECRET-MARKER";
const NB = "nb-open";

/** Runs `fn`, returning everything written to the console and the handler's response. */
async function capture(fn: () => Promise<Response>) {
  const lines: string[] = [];
  const original = { ...console };
  for (const level of ["log", "info", "warn", "error", "debug"] as const) {
    console[level] = (...args: unknown[]) => {
      lines.push(
        args
          .map((a) => (a instanceof Error ? `${a.name}: ${a.message}\n${a.stack}` : String(a)))
          .join(" "),
      );
    };
  }
  let response: Response | undefined;
  let thrown: unknown;
  try {
    response = await fn();
  } catch (e) {
    thrown = e;
  } finally {
    Object.assign(console, original);
  }
  const body = response ? await response.text() : "";
  return { lines: lines.join("\n"), response, body, thrown };
}

function assertClean(run: { lines: string; body: string; thrown: unknown }) {
  assertEquals(run.thrown, undefined, "handler must answer, not throw");
  assert(!run.lines.includes(MARKER), `marker reached the log: ${run.lines}`);
  assert(!run.body.includes(MARKER), `marker reached the response: ${run.body}`);
}

const post = (url: string, body: unknown, headers: Record<string, string> = {}) =>
  new Request(url, {
    method: "POST",
    headers: { Authorization: "Bearer user-token", "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

function userClient(overrides: Record<string, unknown> = {}): DbClient {
  return {
    auth: { getUser: () => Promise.resolve({ data: { user: { id: "user-1" } }, error: null }) },
    from: () => ({
      select: () => ({
        eq: () => ({ single: () => Promise.resolve({ data: { id: NB }, error: null }) }),
      }),
    }),
    rpc: () => Promise.resolve({ data: true, error: null }),
    ...overrides,
  } as unknown as DbClient;
}

const failingResponse = (status: number) =>
  new Response(`{"error":"${MARKER} the provider echoed the prompt"}`, { status });

// ── extract-graph ────────────────────────────────────────────

const extractBody = {
  text: `I met ${MARKER} at ${MARKER} cafe`,
  notebookId: NB,
  existingEntities: [{ name: `${MARKER} Maya`, type: "person", description: MARKER }],
  recentConversation: [{ speaker: "user", text: `${MARKER} hello` }],
};

function extractHandler(fetchImpl: typeof fetch, client = userClient()) {
  return extractGraph({
    userClient: () => client,
    env: (name) => (name === "GROQ_API_KEY" ? "test-key" : undefined),
    fetch: fetchImpl,
  });
}

Deno.test("extract-graph logs no content when Groq answers with an error body", async () => {
  for (const status of [429, 402, 500]) {
    const handle = extractHandler(() => Promise.resolve(failingResponse(status)));
    assertClean(await capture(() => handle(post("http://x/", extractBody))));
  }
});

Deno.test(
  "extract-graph logs no content when the model returns unparseable arguments",
  async () => {
    const handle = extractHandler(() =>
      Promise.resolve(
        Response.json({
          choices: [
            { message: { tool_calls: [{ function: { arguments: `{"entities": ${MARKER}` } }] } },
          ],
        }),
      ),
    );
    assertClean(await capture(() => handle(post("http://x/", extractBody))));
  },
);

Deno.test("extract-graph logs no content when the network throws", async () => {
  const handle = extractHandler(() => Promise.reject(new TypeError(`fetch failed for ${MARKER}`)));
  assertClean(await capture(() => handle(post("http://x/", extractBody))));
});

Deno.test("extract-graph logs no content when the request body is malformed", async () => {
  const handle = extractHandler(() => Promise.reject(new Error("unused")));
  const run = await capture(() => handle(post("http://x/", `{"text": "${MARKER}`)));
  assertClean(run);
  assertEquals(run.response?.status, 500);
});

// ── speak-agent ──────────────────────────────────────────────

function speakHandler(fetchImpl: typeof fetch) {
  return speakAgent({
    userClient: () => userClient(),
    env: (name) => (name === "ELEVENLABS_API_KEY" ? "test-key" : undefined),
    fetch: fetchImpl,
  });
}

Deno.test("speak-agent logs no content when ElevenLabs answers with an error body", async () => {
  const handle = speakHandler(() => Promise.resolve(failingResponse(422)));
  const run = await capture(() => handle(post("http://x/", { text: `Tell me about ${MARKER}` })));
  assertClean(run);
  assertEquals(run.response?.status, 422);
});

Deno.test(
  "speak-agent logs no content when the network throws or the body is malformed",
  async () => {
    const throwing = speakHandler(() =>
      Promise.reject(new TypeError(`fetch failed for ${MARKER}`)),
    );
    assertClean(await capture(() => throwing(post("http://x/", { text: MARKER }))));
    const malformed = speakHandler(() => Promise.reject(new Error("unused")));
    assertClean(await capture(() => malformed(post("http://x/", `{"text": "${MARKER}`))));
  },
);

Deno.test("speak-agent logs no content on success", async () => {
  const handle = speakHandler(() => Promise.resolve(new Response(new Uint8Array([1, 2, 3]))));
  assertClean(await capture(() => handle(post("http://x/", { text: MARKER }))));
});

// ── embed-entities ───────────────────────────────────────────

function embedAdmin(tables: Record<string, { data?: unknown; error?: unknown }>): TableClient {
  return {
    from: (table: string) => {
      const result = Promise.resolve({ data: null, error: null, ...tables[table] });
      const chain: unknown = new Proxy(() => {}, {
        get: (_t, prop) => {
          if (prop === "then") return result.then.bind(result);
          if (prop === "single") return () => result;
          return () => chain;
        },
      });
      return chain;
    },
  } as unknown as TableClient;
}

function embedHandler(admin: TableClient, embedder = new StubEmbedder()) {
  return embedEntities({
    adminClient: () => admin,
    embedder: () => embedder,
    env: (name) => (name === "EMBED_INTERNAL_SECRET" ? "s3cret" : "http://localhost"),
    fetch: () => Promise.resolve(new Response("ok")),
  });
}
const embedReq = (body: unknown) => post("http://x/", body, { "x-internal-secret": "s3cret" });

Deno.test(
  "embed-entities logs no content when a table read fails or returns entity text",
  async () => {
    const entityRows = [{ id: "e1", name: `${MARKER} Maya`, description: `${MARKER} her friend` }];
    const ok = embedHandler(
      embedAdmin({
        notebooks: { data: { user_id: "u1" } },
        entities: { data: entityRows },
        entity_embeddings: { data: [] },
      }),
    );
    assertClean(await capture(() => ok(embedReq({ notebookId: NB }))));

    const failed = embedHandler(
      embedAdmin({
        notebooks: { data: { user_id: "u1" } },
        entities: {
          error: { code: "42501", message: `permission denied for ${MARKER}`, details: MARKER },
        },
      }),
    );
    const run = await capture(() => failed(embedReq({ notebookId: NB })));
    assertClean(run);
    assertEquals(run.response?.status, 500);
  },
);

Deno.test(
  "embed-entities logs no content when the embedder throws or the body is malformed",
  async () => {
    const boom = new StubEmbedder();
    boom.embed = () => Promise.reject(new Error(`embed failed for ${MARKER}`));
    const throwing = embedHandler(
      embedAdmin({
        notebooks: { data: { user_id: "u1" } },
        entities: { data: [{ id: "e1", name: `${MARKER} Maya`, description: null }] },
        entity_embeddings: { data: [] },
      }),
      boom,
    );
    const run = await capture(() => throwing(embedReq({ notebookId: NB })));
    assertClean(run);
    assertEquals(run.response?.status, 500);

    const malformed = embedHandler(embedAdmin({}));
    assertClean(await capture(() => malformed(embedReq(`{"notebookId": "${MARKER}`))));
  },
);

// ── retrieve-memory ──────────────────────────────────────────

function retrieveHandler(client = userClient()) {
  return retrieveMemory({
    userClient: () => client,
    adminClient: () => client,
    embedder: () => new StubEmbedder(),
    log: (fields) => safeLog("retrieve-memory", fields),
  });
}

const retrieveBody = {
  query: `what did I say about ${MARKER}`,
  notebookId: NB,
  state: {
    entities: {
      m: {
        id: "m",
        name: `${MARKER} Maya`,
        type: "person",
        metadata: {},
        mentions: 3,
        firstSeen: "t",
        lastSeen: "t",
      },
    },
    relations: {},
    entries: [{ id: "en1", text: `${MARKER} entry`, createdAt: "t" }],
  },
};

Deno.test("retrieve-memory logs no content on success", async () => {
  assertClean(await capture(() => retrieveHandler()(post("http://x/", retrieveBody))));
});

Deno.test("retrieve-memory logs no content when a dependency throws or rate-limits", async () => {
  const throwing = retrieveHandler(
    userClient({
      rpc: () => Promise.reject(new Error(`rpc failed on ${MARKER}`)),
    }),
  );
  assertClean(await capture(() => throwing(post("http://x/", retrieveBody))));

  const limited = retrieveHandler(
    userClient({
      rpc: () => Promise.resolve({ data: false, error: null }),
    }),
  );
  assertClean(await capture(() => limited(post("http://x/", retrieveBody))));
});

Deno.test("retrieve-memory logs no content when the body is malformed", async () => {
  assertClean(await capture(() => retrieveHandler()(post("http://x/", `{"query": "${MARKER}`))));
});

// ── no direct console use ────────────────────────────────────

Deno.test("function sources print only through safeLog", async () => {
  const offenders: string[] = [];
  for (const dir of [
    "embed-entities",
    "extract-graph",
    "speak-agent",
    "retrieve-memory",
    "_shared",
  ]) {
    for await (const entry of Deno.readDir(new URL(`./${dir}/`, import.meta.url))) {
      if (!entry.name.endsWith(".ts") || entry.name.endsWith(".test.ts")) continue;
      if (entry.name === "eval.ts" || entry.name === "safe-log.ts") continue; // eval.ts is a local dev script
      const source = await Deno.readTextFile(new URL(`./${dir}/${entry.name}`, import.meta.url));
      if (/console\.(log|info|warn|error|debug)/.test(source))
        offenders.push(`${dir}/${entry.name}`);
    }
  }
  assertEquals(offenders, []);
});

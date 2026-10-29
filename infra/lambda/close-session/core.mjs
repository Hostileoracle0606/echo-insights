import { buildJustTalkMessage, justTalkPrompt, writeSessionCardFunction } from "./prompts.mjs";
import {
  buildTranscript,
  justTalkFromModel,
  rememberCandidates,
  rememberItems,
  validateQuotes,
} from "./validate.mjs";

// Lambda's own timeout is 30 s. Stop starting new work well before it, so a
// slow provider ends in a clean 503 instead of a killed invocation.
const defaultDeadlineMs = 27_000;
const supabaseTimeoutMs = 5_000;
const providerTimeoutMs = 7_000;
const maxProviderAttempts = 3;

export function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

export const rejected = (statusCode, code) => jsonResponse(statusCode, { status: "rejected", code });

export class Rejection extends Error {
  constructor(statusCode, code) {
    super(code);
    this.response = rejected(statusCode, code);
  }
}

export function authorizedUserId(event) {
  const value = event?.requestContext?.authorizer?.lambda?.userId;
  return typeof value === "string" && value.length > 0 ? value : null;
}

export function bearerAuthorization(headers = {}) {
  const value = headers.authorization ?? headers.Authorization;
  return typeof value === "string" && /^Bearer\s+\S+/i.test(value) ? value : null;
}

export function notebookIdFrom(event) {
  const value = event?.pathParameters?.notebookId;
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

// PostgREST in.(…) list with every value quoted, so a slug can't break it.
function inList(values) {
  return `in.(${values.map((value) => `"${value.replace(/["\\]/g, (c) => `\\${c}`)}"`).join(",")})`;
}

/** Supabase REST as the signed-in user: RLS decides what is visible. */
export function supabaseClient({ supabaseUrl, publishableKey, authorization, fetchImpl }) {
  async function send(url, init) {
    let response;
    try {
      response = await fetchImpl(url, {
        ...init,
        headers: {
          accept: "application/json",
          apikey: publishableKey,
          authorization,
          ...init.headers,
        },
        signal: AbortSignal.timeout(supabaseTimeoutMs),
      });
    } catch {
      throw new Rejection(503, "providerUnavailable");
    }
    if (response.status === 401 || response.status === 403) {
      throw new Rejection(401, "unauthorized");
    }
    if (!response.ok) throw new Rejection(503, "providerUnavailable");
    try {
      return await response.json();
    } catch {
      throw new Rejection(503, "providerUnavailable");
    }
  }

  return {
    select(table, params) {
      const url = new URL(`/rest/v1/${table}`, supabaseUrl);
      for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
      return send(url, { method: "GET" });
    },
    rpc(name, body) {
      return send(new URL(`/rest/v1/rpc/${name}`, supabaseUrl), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    },
  };
}

export function functionArgs(payload, name) {
  const parts = payload?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return null;
  for (const part of parts) {
    if (part?.functionCall?.name === name) return part.functionCall.args ?? null;
  }
  return null;
}

/**
 * One Gemini generateContent call with retries on network errors and 429,
 * inside the Lambda's deadline. Shared by the closing card and the session
 * brief (text model and TTS model alike).
 */
export async function callGemini({
  fetchImpl,
  credential,
  model,
  body,
  startedAt,
  deadlineMs,
  now,
  sleep,
  metrics,
}) {
  for (let attempt = 0; attempt < maxProviderAttempts; attempt += 1) {
    // Leave room for the save after the model answers.
    if (now() - startedAt + providerTimeoutMs + supabaseTimeoutMs > deadlineMs) {
      throw new Rejection(503, "providerUnavailable");
    }
    metrics.modelCalls += 1;
    let response;
    try {
      response = await fetchImpl(
        `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
        {
          method: "POST",
          headers: { "content-type": "application/json", "x-goog-api-key": credential },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(providerTimeoutMs),
        },
      );
    } catch {
      if (attempt < maxProviderAttempts - 1) {
        await sleep(500 * 2 ** attempt);
        continue;
      }
      throw new Rejection(503, "providerUnavailable");
    }
    if (response.status === 429) {
      if (attempt < maxProviderAttempts - 1) {
        await sleep(500 * 2 ** attempt);
        continue;
      }
      throw new Rejection(429, "rateLimited");
    }
    if (!response.ok) throw new Rejection(503, "providerUnavailable");
    try {
      return await response.json();
    } catch {
      throw new Rejection(502, "invalidProviderResponse");
    }
  }
  throw new Rejection(503, "providerUnavailable");
}

export function createCloseSessionHandler({
  supabaseUrl,
  publishableKey,
  getPermanentCredential,
  fetchImpl,
  model = "gemini-2.5-flash",
  now = () => Date.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  // Ids, counts and latency only: never transcript, title, summary or notes.
  log = (fields) => console.log(JSON.stringify({ source: "close-session", ...fields })),
  deadlineMs = defaultDeadlineMs,
}) {
  async function callModel({ startedAt, providerBody, metrics }) {
    let credential;
    try {
      credential = (await getPermanentCredential()).trim();
      if (!credential) throw new Error("Gemini credential is empty");
    } catch {
      throw new Rejection(503, "providerUnavailable");
    }
    return callGemini({
      fetchImpl,
      credential,
      model,
      body: providerBody,
      startedAt,
      deadlineMs,
      now,
      sleep,
      metrics,
    });
  }

  async function generateJustTalk({ db, notebookId, startedAt, metrics }) {
    const [snapshot, newestTurns] = await Promise.all([
      db.rpc("get_notebook_snapshot", { p_notebook_id: notebookId }),
      db.select("conversation_turns", {
        select: "turn_id,speaker,text,spoken_at,input",
        notebook_id: `eq.${notebookId}`,
        order: "spoken_at.desc,turn_id.desc",
        limit: "1000",
      }),
    ]);
    if (!snapshot || typeof snapshot !== "object") throw new Rejection(404, "notFound");
    if (!Array.isArray(newestTurns)) throw new Rejection(503, "providerUnavailable");

    const turns = [...newestTurns].reverse();
    const userTurns = turns.filter(
      (turn) => turn?.speaker === "user" && typeof turn.text === "string" && turn.text.trim(),
    );
    metrics.turns = turns.length;
    metrics.userTurns = userTurns.length;
    // Nothing the user said means nothing to write that wouldn't be invented.
    if (userTurns.length === 0) throw new Rejection(422, "nothingToSummarize");

    const firstPass = rememberCandidates(snapshot);
    const notebookCounts = new Map();
    if (firstPass.length > 0) {
      const rows = await db.select("user_entities", {
        select: "id,notebook_count",
        id: inList(firstPass.map((item) => item.entityId)),
      });
      if (!Array.isArray(rows)) throw new Rejection(503, "providerUnavailable");
      for (const row of rows) notebookCounts.set(row?.id, Number(row?.notebook_count));
    }
    const candidates = rememberCandidates(snapshot, notebookCounts);
    metrics.candidates = candidates.length;

    const transcript = buildTranscript(turns);
    metrics.transcriptChars = transcript.text.length;
    metrics.transcriptTrimmed = transcript.trimmed;

    const candidateIds = candidates.map((item) => item.entityId);
    const payload = await callModel({
      startedAt,
      metrics,
      providerBody: {
        system_instruction: { parts: [{ text: justTalkPrompt }] },
        contents: [
          {
            role: "user",
            parts: [
              {
                text: buildJustTalkMessage({
                  transcript: transcript.text,
                  trimmed: transcript.trimmed,
                  candidates,
                }),
              },
            ],
          },
        ],
        tools: [{ function_declarations: [writeSessionCardFunction(candidateIds)] }],
        tool_config: {
          function_calling_config: { mode: "ANY", allowed_function_names: ["write_session_card"] },
        },
        generationConfig: { temperature: 0, thinkingConfig: { thinkingBudget: 0 } },
      },
    });
    const fields = justTalkFromModel(functionArgs(payload, "write_session_card"), candidates);
    if (!fields) throw new Rejection(502, "invalidProviderResponse");
    metrics.notes = fields.notes.length;
    metrics.entityNotes = fields.entityNotes.size;

    const card = validateQuotes(
      {
        version: 1,
        notebookId,
        conversationMode: "just_talk",
        sourceRevision: Number(snapshot.revision),
        generatedAt: new Date(now()).toISOString(),
        title: fields.title,
        summary: fields.summary,
        remember: rememberItems(candidates, fields.entityNotes),
        notes: fields.notes,
      },
      userTurns,
    );
    return card;
  }

  // LM-36 adds weekly_debrief, session_prep, first_session and what_landed.
  const generators = { just_talk: generateJustTalk };

  // One pass of steps 1–7. Returns a response, or "stale" when the
  // conversation changed while the card was being written.
  async function closeOnce({ db, notebookId, startedAt, metrics }) {
    const notebooks = await db.select("notebooks", {
      select: "id,revision,conversation_mode",
      id: `eq.${notebookId}`,
      limit: "1",
    });
    if (!Array.isArray(notebooks) || notebooks.length === 0) {
      throw new Rejection(404, "notFound");
    }
    const notebook = notebooks[0];
    metrics.mode = notebook.conversation_mode;
    metrics.revision = Number(notebook.revision);

    const stored = await db.select("session_cards", {
      select: "source_revision,card",
      notebook_id: `eq.${notebookId}`,
      limit: "1",
    });
    if (
      Array.isArray(stored) &&
      stored.length > 0 &&
      Number(stored[0].source_revision) === Number(notebook.revision) &&
      stored[0].card
    ) {
      metrics.cached = true;
      return jsonResponse(200, { status: "ready", card: stored[0].card });
    }

    const generate = generators[notebook.conversation_mode];
    if (!generate) throw new Rejection(501, "notImplemented");

    const card = await generate({ db, notebookId, startedAt, metrics });
    const saved = await db.rpc("save_session_card", {
      p_notebook_id: notebookId,
      p_source_revision: card.sourceRevision,
      p_card: card,
      p_title: card.title,
      p_summary: card.summary,
    });
    if (saved?.status === "saved" && saved.card) {
      return jsonResponse(200, { status: "ready", card: saved.card });
    }
    if (saved?.status === "stale") return "stale";
    if (saved?.code === "notFound") throw new Rejection(404, "notFound");
    throw new Rejection(503, "providerUnavailable");
  }

  return async function handle(event) {
    const startedAt = now();
    const userId = authorizedUserId(event);
    if (!userId) return rejected(401, "unauthorized");
    const authorization = bearerAuthorization(event?.headers);
    if (!authorization) return rejected(401, "unauthorized");
    const notebookId = notebookIdFrom(event);
    if (!notebookId) return rejected(400, "invalidRequest");

    const db = supabaseClient({ supabaseUrl, publishableKey, authorization, fetchImpl });
    const metrics = { modelCalls: 0, passes: 0 };
    let response;
    try {
      for (let pass = 0; pass < 2 && !response; pass += 1) {
        metrics.passes = pass + 1;
        const outcome = await closeOnce({ db, notebookId, startedAt, metrics });
        if (outcome !== "stale") response = outcome;
      }
      response ??= rejected(409, "stale");
    } catch (error) {
      response = error instanceof Rejection ? error.response : rejected(503, "providerUnavailable");
    }

    log({
      event: "close",
      notebookId,
      userId,
      statusCode: response.statusCode,
      code: response.statusCode === 200 ? undefined : JSON.parse(response.body).code,
      latencyMs: now() - startedAt,
      ...metrics,
    });
    return response;
  };
}

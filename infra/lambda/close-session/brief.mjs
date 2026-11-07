import { guardHandler, safeLog } from "./safe-log.mjs";
import {
  Rejection,
  authorizedUserId,
  bearerAuthorization,
  callGemini,
  functionArgs,
  jsonResponse,
  notebookIdFrom,
  rejected,
  supabaseClient,
} from "./core.mjs";
import {
  briefFromModel,
  briefPrompt,
  buildBriefMessage,
  writeSessionBriefFunction,
} from "./brief-prompts.mjs";
import { redactTexts, redactTurns } from "./redact.mjs";
import { effectiveRevision, parseBriefRequest, readBody } from "./client-input.mjs";
import { buildTranscript } from "./validate.mjs";

const defaultDeadlineMs = 27_000;
const defaultSampleRate = 24_000;
const speakPrefix = "Say warmly, unhurried and natural, like a friend catching up: ";

// The TTS preview model's per-minute limit is tight: a 429 needs seconds,
// not the closing card's sub-second retries. callGemini's deadline guard
// still stops before the save would miss the Lambda's budget.
const briefRetryDelaysMs = [2000, 4000, 8000];
const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

const timeOf = (value) => (typeof value === "string" ? Date.parse(value) : Number.NaN);

/** "2026-10-31 (Saturday)", in UTC. */
function conversationDate(milliseconds) {
  const date = new Date(milliseconds);
  return `${date.toISOString().slice(0, 10)} (${weekdays[date.getUTCDay()]})`;
}

/** Runs one Gemini call, noting in the log which call a rate limit hit. */
async function rateLimitTagged(metrics, label, call) {
  try {
    return await call();
  } catch (error) {
    if (error instanceof Rejection && error.response.statusCode === 429) {
      metrics.rateLimitedBy = label;
    }
    throw error;
  }
}
const strings = (value) =>
  Array.isArray(value) ? value.filter((item) => typeof item === "string") : [];

/**
 * The app's lists with every forgotten name redacted, in one call with the
 * transcript (see redactTexts). Same shapes back.
 */
async function redactAppInput(db, request) {
  const texts = [];
  const take = (text) => {
    texts.push(text);
    return texts.length - 1;
  };
  const turnAt = request.turns.map((turn) => take(turn.text));
  const followUpAt = request.followUps.map(take);
  const questionAt = request.questions.map((item) => ({
    name: take(item.name),
    questions: item.questions.map(take),
  }));
  const topAt = request.topEntities.map((item) => take(item.name));
  const previousAt = request.previous && {
    focus: request.previous.focus.map(take),
    openingThread: take(request.previous.openingThread),
  };
  const out = await redactTexts(db, texts);
  return {
    turns: request.turns.map((turn, index) => ({ ...turn, text: out[turnAt[index]] })),
    followUps: followUpAt.map((at) => out[at]),
    questions: questionAt.map((at) => ({ name: out[at.name], questions: at.questions.map((q) => out[q]) })),
    topEntities: request.topEntities.map((item, index) => ({ ...item, name: out[topAt[index]] })),
    previous: previousAt && {
      focus: previousAt.focus.map((at) => out[at]),
      openingThread: out[previousAt.openingThread],
    },
  };
}

/**
 * POST /v1/notebooks/{id}/brief: writes the opening for the user's next
 * conversation (a brief, plus the opening line spoken by Gemini TTS) into
 * session_briefs. Independent of the closing card: it has its own function,
 * and if anything fails here the previous brief simply stays.
 *
 * v2 (LM-56) splits it in two so no real name reaches the text model: a
 * write request carries the app's text with names swapped and gets the
 * brief back unsaved; the app swaps the names back and sends a speak request
 * with the real opening line, gets the audio, and saves both through
 * save_session_brief. See contracts/session-brief-v1.md.
 */
export function createSessionBriefHandler({
  supabaseUrl,
  publishableKey,
  getPermanentCredential,
  fetchImpl,
  model = "gemini-2.5-flash",
  ttsModel = "gemini-2.5-flash-preview-tts",
  voice = "Aoede",
  now = () => Date.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  // Ids, counts and latency only: never transcript, brief or line text.
  log = (fields) => safeLog("session-brief", fields),
  deadlineMs = defaultDeadlineMs,
}) {
  async function credential() {
    try {
      const value = (await getPermanentCredential()).trim();
      if (!value) throw new Error("Gemini credential is empty");
      return value;
    } catch {
      throw new Rejection(503, "providerUnavailable");
    }
  }

  // One credential read per request, however many calls it makes (keyed by
  // the request's metrics object).
  const credentials = new WeakMap();
  const gemini = async ({ metrics, startedAt }) => {
    if (!credentials.has(metrics)) credentials.set(metrics, await credential());
    return geminiCall({ metrics, startedAt, credential: credentials.get(metrics) });
  };
  const geminiCall = ({ metrics, startedAt, credential: apiKey }) => ({
    fetchImpl,
    credential: apiKey,
    startedAt,
    deadlineMs,
    now,
    sleep,
    metrics,
    retryDelaysMs: briefRetryDelaysMs,
  });

  const lastSpokenOr = (userTurns) => {
    const lastSpoken = timeOf(userTurns.at(-1)?.spoken_at);
    return Number.isNaN(lastSpoken) ? now() : lastSpoken;
  };

  // The text model: one forced write_session_brief call. Everything it reads
  // is passed in; on the v2 path all of it came from the app, names swapped.
  async function writeBrief({ metrics, startedAt, ...message }) {
    const call = await gemini({ metrics, startedAt });
    const payload = await rateLimitTagged(metrics, "text", () =>
      callGemini({
        ...call,
        model,
        body: {
          system_instruction: { parts: [{ text: briefPrompt }] },
          contents: [
            {
              role: "user",
              parts: [
                {
                  text: buildBriefMessage({
                    conversationDate: message.conversationDate,
                    transcript: message.transcript.text,
                    trimmed: message.transcript.trimmed,
                    previous: message.previous,
                    followUps: message.followUps,
                    questions: message.questions,
                    topEntities: message.topEntities,
                  }),
                },
              ],
            },
          ],
          tools: [{ function_declarations: [writeSessionBriefFunction()] }],
          tool_config: {
            function_calling_config: {
              mode: "ANY",
              allowed_function_names: ["write_session_brief"],
            },
          },
          generationConfig: { temperature: 0, thinkingConfig: { thinkingBudget: 0 } },
        },
      }),
    );
    const brief = briefFromModel(functionArgs(payload, "write_session_brief"));
    if (!brief) throw new Rejection(502, "invalidProviderResponse");
    return brief;
  }

  // TTS: the opening line, and only that line, in Lumen's voice.
  async function speak({ metrics, startedAt, openingLine }) {
    const call = await gemini({ metrics, startedAt });
    const callsBeforeSpeech = metrics.modelCalls;
    let speech;
    try {
      speech = await rateLimitTagged(metrics, "tts", () =>
        callGemini({
          ...call,
          model: ttsModel,
          body: {
            contents: [{ parts: [{ text: `${speakPrefix}${openingLine}` }] }],
            generationConfig: {
              responseModalities: ["AUDIO"],
              speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voice } } },
            },
          },
        }),
      );
    } finally {
      metrics.ttsCalls = metrics.modelCalls - callsBeforeSpeech;
    }
    const inline = speech?.candidates?.[0]?.content?.parts?.find(
      (part) => part?.inlineData?.data,
    )?.inlineData;
    if (typeof inline?.data !== "string" || inline.data.length === 0) {
      throw new Rejection(502, "invalidProviderResponse");
    }
    const sampleRate = Number(/rate=(\d+)/.exec(inline.mimeType ?? "")?.[1] ?? defaultSampleRate);
    metrics.audioBase64Chars = inline.data.length;
    return { audioBase64: inline.data, sampleRate };
  }

  // v2 write: the app's text, redacted for forgotten names; the brief comes
  // back unsaved for the app to swap the names back into.
  async function writeFromApp({ db, notebook, startedAt, metrics, request }) {
    const input = await redactAppInput(db, request);
    const userTurns = input.turns.filter(
      (turn) => turn.speaker === "user" && turn.text.trim(),
    );
    metrics.appTurns = input.turns.length;
    metrics.userTurns = userTurns.length;
    if (userTurns.length === 0) throw new Rejection(422, "nothingToSummarize");
    metrics.hasPrevious = Boolean(input.previous);
    metrics.followUps = input.followUps.length;
    metrics.entityQuestions = input.questions.length;
    metrics.topEntities = input.topEntities.length;

    const transcript = buildTranscript(input.turns);
    metrics.transcriptChars = transcript.text.length;
    metrics.transcriptTrimmed = transcript.trimmed;

    const brief = await writeBrief({
      metrics,
      startedAt,
      conversationDate: conversationDate(lastSpokenOr(userTurns)),
      transcript,
      previous: input.previous,
      followUps: input.followUps,
      questions: input.questions,
      topEntities: input.topEntities,
    });
    return {
      status: "ready",
      brief,
      sourceRevision: effectiveRevision(notebook.revision, request.sourceRevision),
    };
  }

  // v2 speak: the real opening line the app swapped back. The same
  // "unchanged" checks run again first, so a newer brief saved meanwhile is
  // not overwritten by this one.
  async function speakForApp({ db, notebookId, startedAt, metrics, request }) {
    const checked = await check({ db, notebookId, metrics, revision: request.sourceRevision });
    if (checked === "unchanged") return { status: "unchanged" };
    if (request.sourceRevision > Number(checked.notebook.revision)) {
      throw new Rejection(400, "invalidRequest");
    }
    const { audioBase64, sampleRate } = await speak({
      metrics,
      startedAt,
      openingLine: request.openingLine,
    });
    return { status: "ready", audioBase64, sampleRate };
  }

  // Reads the notebook and decides whether a brief at [revision] (the
  // notebook's own when null) would be news: "unchanged" when the stored one
  // already covers it or a newer session's brief must not be replaced.
  async function check({ db, notebookId, metrics, revision = null }) {
    const notebooks = await db.select("notebooks", {
      select: "id,revision,conversation_mode,ended_at,transcript_forgotten_at",
      id: `eq.${notebookId}`,
      limit: "1",
    });
    if (!Array.isArray(notebooks) || notebooks.length === 0) throw new Rejection(404, "notFound");
    const notebook = notebooks[0];
    metrics.mode = notebook.conversation_mode;
    metrics.revision = Number(notebook.revision);
    if (notebook.conversation_mode !== "just_talk") throw new Rejection(501, "notImplemented");
    // Auto-forget removed some of this conversation's turns; a brief written
    // from the rest would be a fragment. Keep the one Lumen already has.
    if (notebook.transcript_forgotten_at) {
      metrics.forgotten = true;
      return "unchanged";
    }

    // One row per user. It is both the "already done" check and the previous
    // brief the model carries forward.
    const rows = await db.select("session_briefs", {
      select: "source_notebook_id,source_revision,brief,created_at",
    });
    if (!Array.isArray(rows)) throw new Rejection(503, "providerUnavailable");
    const stored = rows[0] ?? null;
    if (stored) {
      const sameNotebook = stored.source_notebook_id === notebookId;
      // A repeated close: this revision (or a later one) is already written.
      if (
        sameNotebook &&
        Number(stored.source_revision) >= effectiveRevision(notebook.revision, revision)
      ) {
        metrics.cached = true;
        return "unchanged";
      }
      // A delayed retry for an older session must not overwrite a newer brief.
      if (!sameNotebook && timeOf(stored.created_at) > timeOf(notebook.ended_at)) {
        metrics.superseded = true;
        return "unchanged";
      }
    }
    return { notebook, stored };
  }

  async function write({ db, notebookId, startedAt, metrics, request }) {
    const checked = await check({
      db,
      notebookId,
      metrics,
      revision: request.version === 2 ? request.sourceRevision : null,
    });
    if (checked === "unchanged") return checked;
    const { notebook, stored } = checked;
    if (request.version === 2) {
      return writeFromApp({ db, notebook, startedAt, metrics, request });
    }

    const [newestTurns, followUps, questionEntities, topEntities] = await Promise.all([
      db.select("conversation_turns", {
        select: "turn_id,speaker,text,spoken_at,input",
        notebook_id: `eq.${notebookId}`,
        order: "spoken_at.desc,turn_id.desc",
        limit: "1000",
      }),
      db.select("follow_ups", {
        answered: "eq.false",
        select: "question",
        order: "created_at.desc",
        limit: "10",
      }),
      db.select("entities", {
        questions: "not.is.null",
        select: "name,questions",
        order: "last_seen.desc",
        limit: "10",
      }),
      db.select("user_entities", {
        select: "name,type,mentions",
        order: "mentions.desc",
        limit: "15",
      }),
    ]);
    if (![newestTurns, followUps, questionEntities, topEntities].every(Array.isArray)) {
      throw new Rejection(503, "providerUnavailable");
    }

    const turns = await redactTurns(db, [...newestTurns].reverse());
    const userTurns = turns.filter(
      (turn) => turn?.speaker === "user" && typeof turn.text === "string" && turn.text.trim(),
    );
    metrics.turns = turns.length;
    metrics.userTurns = userTurns.length;
    // Nothing the user said means nothing to open with that wouldn't be invented.
    if (userTurns.length === 0) throw new Rejection(422, "nothingToSummarize");

    const followUpQuestions = followUps
      .map((row) => row?.question)
      .filter((q) => typeof q === "string" && q.trim());
    const questions = questionEntities
      .map((row) => ({ name: row?.name, questions: strings(row?.questions) }))
      .filter((row) => typeof row.name === "string" && row.questions.length > 0);
    const entities = topEntities.filter((row) => typeof row?.name === "string");
    metrics.hasPrevious = Boolean(stored?.brief);
    metrics.followUps = followUpQuestions.length;
    metrics.entityQuestions = questions.length;
    metrics.topEntities = entities.length;

    const transcript = buildTranscript(turns);
    metrics.transcriptChars = transcript.text.length;
    metrics.transcriptTrimmed = transcript.trimmed;

    const brief = await writeBrief({
      metrics,
      startedAt,
      conversationDate: conversationDate(lastSpokenOr(userTurns)),
      transcript,
      previous: stored?.brief && typeof stored.brief === "object" ? stored.brief : null,
      followUps: followUpQuestions,
      questions,
      topEntities: entities,
    });
    const { audioBase64, sampleRate } = await speak({
      metrics,
      startedAt,
      openingLine: brief.openingLine,
    });

    const saved = await db.rpc("save_session_brief", {
      p_notebook_id: notebookId,
      p_source_revision: Number(notebook.revision),
      p_brief: brief,
      p_audio_base64: audioBase64,
      p_sample_rate: sampleRate,
    });
    if (saved?.status === "saved") return "ready";
    if (saved?.status === "unchanged") return "unchanged";
    if (saved?.code === "notFound") throw new Rejection(404, "notFound");
    throw new Rejection(503, "providerUnavailable");
  }

  async function handle(event) {
    const startedAt = now();
    const userId = authorizedUserId(event);
    if (!userId) return rejected(401, "unauthorized");
    const authorization = bearerAuthorization(event?.headers);
    if (!authorization) return rejected(401, "unauthorized");
    const notebookId = notebookIdFrom(event);
    if (!notebookId) return rejected(400, "invalidRequest");

    const request = parseBriefRequest(readBody(event));
    if (!request) return rejected(400, "invalidRequest");

    const db = supabaseClient({ supabaseUrl, publishableKey, authorization, fetchImpl });
    const metrics = { modelCalls: 0, version: request.version };
    let response;
    try {
      if (request.version === 1) {
        response = jsonResponse(200, {
          status: await write({ db, notebookId, startedAt, metrics, request }),
        });
      } else if (request.kind === "speak") {
        metrics.stage = "speak";
        response = jsonResponse(
          200,
          await speakForApp({ db, notebookId, startedAt, metrics, request }),
        );
      } else {
        metrics.stage = "write";
        const result = await write({ db, notebookId, startedAt, metrics, request });
        response = jsonResponse(200, result === "unchanged" ? { status: result } : result);
      }
    } catch (error) {
      response = error instanceof Rejection ? error.response : rejected(503, "providerUnavailable");
    }

    log({
      event: "brief",
      notebookId,
      userId,
      statusCode: response.statusCode,
      code: response.statusCode === 200 ? undefined : JSON.parse(response.body).code,
      outcome: response.statusCode === 200 ? JSON.parse(response.body).status : undefined,
      latencyMs: now() - startedAt,
      ...metrics,
    });
    return response;
  }

  return guardHandler("session-brief", handle, () => rejected(503, "providerUnavailable"), log);
}

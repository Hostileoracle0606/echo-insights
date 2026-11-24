import { createHash, randomUUID } from "node:crypto";

import { guardHandler } from "./safe-log.mjs";
import { extractGraphFunction, granularPrompt, wikiPrompt } from "./prompts.mjs";

// Model output targets 800 characters (see prompts.mjs). The additional 200
// characters absorb provider variance while this hard boundary guarantees that
// every accepted description can be reused as future extraction context.
const maxEntityDescriptionLength = 1000;

const entityTypes = new Set([
  "person",
  "place",
  "organization",
  "project",
  "event",
  "activity",
  "concept",
  "emotion",
  "other",
]);

function jsonResponse(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

function authorizedUserId(event) {
  const value = event?.requestContext?.authorizer?.lambda?.userId;
  return typeof value === "string" && value.length > 0 ? value : null;
}

function bearerAuthorization(headers = {}) {
  const value = headers.authorization ?? headers.Authorization;
  return typeof value === "string" && /^Bearer\s+\S+/i.test(value) ? value : null;
}

function notebookIdFrom(event) {
  const value = event?.pathParameters?.notebookId;
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null;
}

function parseBody(event) {
  if (typeof event?.body !== "string") return null;
  try {
    const text = event.isBase64Encoded
      ? Buffer.from(event.body, "base64").toString("utf8")
      : event.body;
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function extractionInputHash(body) {
  return createHash("sha256")
    .update(
      canonicalJson({
        text: body.text.trim(),
        mode: body.mode,
      }),
    )
    .digest("hex");
}

function boundedString(value, maxLength, { allowEmpty = false } = {}) {
  return (
    typeof value === "string" &&
    value.length <= maxLength &&
    (allowEmpty || value.trim().length > 0)
  );
}

function truncateString(value, maxLength) {
  if (typeof value !== "string" || value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 1).trimEnd()}…`;
}

function normalizeEntityDescription(entity) {
  if (!entity || typeof entity !== "object" || Array.isArray(entity)) return entity;
  if (typeof entity.description !== "string") return entity;
  return {
    ...entity,
    description: truncateString(entity.description, maxEntityDescriptionLength),
  };
}

function normalizeRequest(body) {
  const context = body?.context;
  if (!body || !context || typeof context !== "object" || Array.isArray(context)) return body;
  return {
    ...body,
    context: {
      ...context,
      entities: Array.isArray(context.entities)
        ? context.entities.map(normalizeEntityDescription)
        : context.entities,
    },
  };
}

const factStatuses = new Set(["confirmed", "proposed", "cancelled"]);
const maxFacts = 20;
const placeholderValues = new Set(["unknown", "none", "n/a", "na", "null", "nothing", "not stated", "unspecified", "?"]);

/**
 * EC-03: the facts the model returned, each checked on its own. A malformed
 * fact is dropped; it never costs the turn its entities and relations. The
 * database decides repeat / supersede / pinned when the app records them.
 */
function sanitizeFacts(value) {
  if (!Array.isArray(value)) return [];
  const facts = [];
  for (const raw of value) {
    if (facts.length >= maxFacts) break;
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const entity = typeof raw.entity === "string" ? raw.entity.trim() : "";
    const attribute = typeof raw.attribute === "string"
      ? raw.attribute.trim().toLowerCase().replace(/\s+/g, " ")
      : "";
    if (!entity || entity.length > 200 || !attribute || attribute.length > 80) continue;
    if (!factStatuses.has(raw.status)) continue;
    const fact = { entity, attribute };
    if (typeof raw.valueNum === "number" && Number.isFinite(raw.valueNum)) fact.valueNum = raw.valueNum;
    if (typeof raw.valueText === "string" && raw.valueText.trim() && raw.valueText.length <= 500) {
      fact.valueText = raw.valueText.trim();
    }
    if (fact.valueNum === undefined && fact.valueText === undefined) continue;
    if (typeof raw.unit === "string" && raw.unit.trim() && raw.unit.length <= 40) fact.unit = raw.unit.trim();
    fact.status = raw.status;
    if (raw.eventDate != null || raw.eventAt != null) {
      const date = typeof raw.eventDate === "string" ? raw.eventDate : "";
      const eventAt = typeof raw.eventAt === "string" ? raw.eventAt : `${date}T12:00:00Z`;
      if (!/^\d{4}-\d{2}-\d{2}T/.test(eventAt) || !Number.isFinite(Date.parse(eventAt))) continue;
      fact.eventAt = eventAt;
    }
    // A previous value is stored as real history, so a placeholder the model
    // filled in ("unknown") or one equal to the new value is dropped.
    if (typeof raw.previousValueNum === "number" && Number.isFinite(raw.previousValueNum) &&
        raw.previousValueNum !== fact.valueNum) {
      fact.previousValueNum = raw.previousValueNum;
    }
    if (typeof raw.previousValueText === "string" && raw.previousValueText.trim() &&
        raw.previousValueText.length <= 500 &&
        !placeholderValues.has(raw.previousValueText.trim().toLowerCase()) &&
        raw.previousValueText.trim().toLowerCase() !== fact.valueText?.toLowerCase()) {
      fact.previousValueText = raw.previousValueText.trim();
    }
    facts.push(fact);
  }
  return facts;
}

function normalizePatch(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const { facts, ...rest } = value;
  const cleanFacts = sanitizeFacts(facts);
  return {
    ...rest,
    entities: Array.isArray(value.entities)
      ? value.entities.map(normalizeEntityDescription)
      : value.entities,
    ...(cleanFacts.length ? { facts: cleanFacts } : {}),
  };
}

function validContext(context) {
  if (!context || typeof context !== "object" || Array.isArray(context)) return false;
  if (!Array.isArray(context.entities) || context.entities.length > 20) return false;
  if (!Array.isArray(context.relations) || context.relations.length > 30) return false;
  if (!Array.isArray(context.recentConversation) || context.recentConversation.length > 4) {
    return false;
  }

  for (const entity of context.entities) {
    if (!entity || typeof entity !== "object") return false;
    if (!boundedString(entity.id, 160) || !boundedString(entity.name, 200)) return false;
    if (!entityTypes.has(entity.type)) return false;
    if (
      entity.description != null &&
      !boundedString(entity.description, maxEntityDescriptionLength, { allowEmpty: true })
    ) {
      return false;
    }
  }
  for (const relation of context.relations) {
    if (!relation || typeof relation !== "object") return false;
    if (
      !boundedString(relation.id, 320) ||
      !boundedString(relation.source, 160) ||
      !boundedString(relation.target, 160) ||
      !boundedString(relation.label, 160)
    ) {
      return false;
    }
  }
  for (const turn of context.recentConversation) {
    if (!turn || typeof turn !== "object") return false;
    if ((turn.role !== "user" && turn.role !== "assistant") || !boundedString(turn.text, 4000)) {
      return false;
    }
  }
  if (context.answeringFollowUp != null) {
    const followUp = context.answeringFollowUp;
    if (!followUp || typeof followUp !== "object") return false;
    if (!boundedString(followUp.question, 1000)) return false;
    if (!boundedString(followUp.reason ?? "", 1000, { allowEmpty: true })) return false;
  }
  return true;
}

function validSpokenAt(value) {
  return value == null || (
    boundedString(value, 40) &&
    /^\d{4}-\d{2}-\d{2}T/.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

function validRequest(body) {
  return (
    body &&
    validSpokenAt(body.spokenAt) &&
    boundedString(body.turnId, 100) &&
    boundedString(body.extractorVersion, 100) &&
    boundedString(body.text, 50000) &&
    body.text.trim().length >= 6 &&
    (body.mode === "wiki" || body.mode === "granular") &&
    validContext(body.context)
  );
}

const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** "2026-11-22 (Sunday)": the user's own calendar date when spokenAt has their offset. */
function saidAtLine(spokenAt, nowMs) {
  const date = typeof spokenAt === "string" && /^\d{4}-\d{2}-\d{2}/.test(spokenAt)
    ? spokenAt.slice(0, 10)
    : new Date(nowMs).toISOString().slice(0, 10);
  const [year, month, day] = date.split("-").map(Number);
  return `${date} (${weekdays[new Date(Date.UTC(year, month - 1, day)).getUTCDay()]})`;
}

function buildUserMessage(text, context, { factKeys = [], spokenAt = null, nowMs = Date.now() } = {}) {
  const namesById = new Map(context.entities.map((entity) => [entity.id, entity.name]));
  const entities = context.entities.length
    ? context.entities
        .map(
          (entity) =>
            `- ${entity.name} (${entity.type})${entity.description ? ` - ${entity.description}` : ""}`,
        )
        .join("\n")
    : "(none yet)";
  const relations = context.relations.length
    ? context.relations
        .map(
          (relation) =>
            `- [${relation.id}] ${namesById.get(relation.source) ?? relation.source} --${relation.label}--> ${namesById.get(relation.target) ?? relation.target}`,
        )
        .join("\n")
    : "(none yet)";
  const recent = context.recentConversation.length
    ? context.recentConversation.map((turn) => `- ${turn.role}: ${turn.text}`).join("\n")
    : "(none)";
  const followUp = context.answeringFollowUp;
  const followUpSection = followUp
    ? `\n\nQUESTION BEING ANSWERED (grounding only):\n- ${followUp.question}${followUp.reason ? ` — ${followUp.reason}` : ""}`
    : "";

  const keys = factKeys.length
    ? factKeys
        .map((key) =>
          `- ${namesById.get(key.entityId) ?? key.entityId}.${key.attribute}${key.unit ? ` (${key.unit})` : ""}`,
        )
        .join("\n")
    : "(none yet)";

  return `SAID AT: ${saidAtLine(spokenAt, nowMs)}

EXISTING ENTITIES (reuse these spellings for the same thing):
${entities}

EXISTING FACT KEYS (entity.attribute — reuse these for the same kind of value):
${keys}

EXISTING RELATIONS (each prefixed with its [id] — use these IDs verbatim in supersedes when contradicted):
${relations}

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these):
${recent}${followUpSection}

NEW UTTERANCE:
"""${text.trim()}"""`;
}

function validPatch(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  if (!Array.isArray(value.entities) || !Array.isArray(value.relations)) return false;
  if (value.entities.length > 100 || value.relations.length > 200) return false;
  if (value.supersedes != null && !Array.isArray(value.supersedes)) return false;

  for (const entity of value.entities) {
    if (!entity || typeof entity !== "object") return false;
    if (!boundedString(entity.name, 200) || !entityTypes.has(entity.type)) return false;
    if (
      entity.description != null &&
      !boundedString(entity.description, maxEntityDescriptionLength, { allowEmpty: true })
    ) {
      return false;
    }
    if (
      entity.metadata != null &&
      (typeof entity.metadata !== "object" || Array.isArray(entity.metadata))
    ) {
      return false;
    }
    if (
      entity.questions != null &&
      (!Array.isArray(entity.questions) ||
        entity.questions.some((question) => typeof question !== "string"))
    ) {
      return false;
    }
  }
  for (const relation of value.relations) {
    if (!relation || typeof relation !== "object") return false;
    if (
      !boundedString(relation.source, 200) ||
      !boundedString(relation.target, 200) ||
      !boundedString(relation.label, 160)
    ) {
      return false;
    }
    if (
      relation.metadata != null &&
      (typeof relation.metadata !== "object" || Array.isArray(relation.metadata))
    ) {
      return false;
    }
  }
  if (value.supersedes?.some((id) => typeof id !== "string")) return false;
  if (value.facts != null && (!Array.isArray(value.facts) || value.facts.length > maxFacts)) return false;
  return true;
}

/**
 * The attribute names already stored for the turn's entities, read with the
 * user's own token. Facts are a bonus: when this fails, extraction goes on
 * without them.
 */
async function readFactKeys({ supabaseUrl, publishableKey, authorization, fetchImpl, entityIds }) {
  if (!entityIds.length) return [];
  try {
    const response = await fetchImpl(new URL("/rest/v1/rpc/list_memory_fact_keys", supabaseUrl), {
      method: "POST",
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        apikey: publishableKey,
        authorization,
      },
      body: JSON.stringify({ p_entity_ids: entityIds }),
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) return [];
    const keys = await response.json();
    return Array.isArray(keys)
      ? keys.filter((k) => k && typeof k.entityId === "string" && typeof k.attribute === "string")
      : [];
  } catch {
    return [];
  }
}

function patchFromProviderResponse(payload) {
  const parts = payload?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return null;
  for (const part of parts) {
    const call = part?.functionCall;
    if (call?.name === "extract_graph") {
      const args = call.args;
      if (!args || !Array.isArray(args.entities) || !Array.isArray(args.relations)) continue;
      const patch = normalizePatch({
        entities: args.entities,
        relations: args.relations,
        supersedes: args.supersedes ?? [],
        facts: args.facts,
      });
      if (validPatch(patch)) return patch;
    }
  }
  return null;
}

// Joins the texts for one call: a control character is a gap to the
// database's matcher, so no name spans two of them. Taken out of each first.
const redactionSeparator = "\u0001";

/**
 * [body] with every forgotten name in the turn, the recent conversation and
 * the question being answered replaced by "someone", through one
 * redact_forgotten_text call as the user. Throws on any failure.
 */
async function redactRequest({ supabaseUrl, publishableKey, authorization, fetchImpl, body }) {
  const followUp = body.context.answeringFollowUp;
  const texts = [
    body.text,
    ...body.context.recentConversation.map((turn) => turn.text),
    ...(followUp ? [followUp.question ?? "", followUp.reason ?? ""] : []),
  ].map((text) => String(text).replaceAll(redactionSeparator, ""));
  const response = await fetchImpl(new URL("/rest/v1/rpc/redact_forgotten_text", supabaseUrl), {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      apikey: publishableKey,
      authorization,
    },
    body: JSON.stringify({ p_text: texts.join(redactionSeparator) }),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error("redaction unavailable");
  const out = await response.json();
  if (typeof out !== "string") throw new Error("redaction malformed");
  const parts = out.split(redactionSeparator);
  if (parts.length !== texts.length) throw new Error("redaction misaligned");
  const turns = body.context.recentConversation.length;
  return {
    text: parts[0],
    context: {
      ...body.context,
      recentConversation: body.context.recentConversation.map((turn, index) => ({
        ...turn,
        text: parts[1 + index],
      })),
      answeringFollowUp: followUp
        ? { ...followUp, question: parts[1 + turns], reason: parts[2 + turns] }
        : followUp,
    },
  };
}

export function createExtractGraphHandler({
  supabaseUrl,
  publishableKey,
  getPermanentCredential,
  acquireExtraction,
  completeExtraction,
  fetchImpl,
  model = "gemini-2.5-flash",
  now = () => Date.now(),
  newOwnerToken = () => randomUUID(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
}) {
  async function handle(event) {
    const userId = authorizedUserId(event);
    if (!userId) return jsonResponse(401, { error: "unauthorized" });

    const authorization = bearerAuthorization(event?.headers);
    if (!authorization) return jsonResponse(401, { error: "unauthorized" });

    const notebookId = notebookIdFrom(event);
    const body = normalizeRequest(parseBody(event));
    if (!notebookId || !validRequest(body)) {
      return jsonResponse(400, { error: "invalidRequest" });
    }

    const notebookUrl = new URL("/rest/v1/notebooks", supabaseUrl);
    notebookUrl.searchParams.set("select", "id");
    notebookUrl.searchParams.set("id", `eq.${notebookId}`);
    notebookUrl.searchParams.set("limit", "1");

    try {
      const response = await fetchImpl(notebookUrl, {
        method: "GET",
        headers: { accept: "application/json", apikey: publishableKey, authorization },
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) {
        return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
      }
      const notebooks = await response.json();
      if (!Array.isArray(notebooks) || notebooks.length === 0) {
        return jsonResponse(404, { status: "rejected", code: "notFound" });
      }
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    // LM-63: a forgotten name never reaches the model, whatever the app knew.
    // A reinstalled app or a second device has no list of the people the user
    // forgot, so the turn, the recent conversation and the question being
    // answered go through the database's redaction, with the user's own
    // token. Fails closed: no answer, no model call. The cache key and hash
    // stay those of the request, so a retry finds its result.
    let redacted;
    try {
      redacted = await redactRequest({ supabaseUrl, publishableKey, authorization, fetchImpl, body });
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    const cacheKey = `${userId}:${notebookId}:${body.turnId}:${body.extractorVersion}`;
    const inputHash = extractionInputHash(body);
    const ownerToken = newOwnerToken();
    const claimedAt = now();
    let acquisition;
    try {
      acquisition = await acquireExtraction({
        id: cacheKey,
        inputHash,
        ownerToken,
        now: claimedAt,
        leaseExpiresAt: claimedAt + 35_000,
        expiresAt: Math.floor(claimedAt / 1000) + 7 * 24 * 60 * 60,
      });
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }
    if (acquisition.status === "completed") {
      const normalizedPatch = normalizePatch(acquisition.patch);
      return validPatch(normalizedPatch)
        ? jsonResponse(200, { patch: normalizedPatch })
        : jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }
    if (acquisition.status === "pending") {
      return jsonResponse(409, {
        status: "rejected",
        code: "inProgress",
        retryAfterMs: acquisition.retryAfterMs,
      });
    }
    if (acquisition.status === "mismatch") {
      return jsonResponse(409, { status: "rejected", code: "requestIdReused" });
    }
    if (acquisition.status !== "acquired") {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    let permanentCredential;
    try {
      permanentCredential = (await getPermanentCredential()).trim();
      if (!permanentCredential) throw new Error("Gemini credential is empty");
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    const factKeys = await readFactKeys({
      supabaseUrl,
      publishableKey,
      authorization,
      fetchImpl,
      entityIds: redacted.context.entities.map((entity) => entity.id),
    });

    const providerBody = {
      system_instruction: {
        parts: [{ text: body.mode === "wiki" ? wikiPrompt : granularPrompt }],
      },
      contents: [
        {
          role: "user",
          parts: [{
            text: buildUserMessage(redacted.text, redacted.context, {
              factKeys,
              spokenAt: body.spokenAt,
              nowMs: now(),
            }),
          }],
        },
      ],
      tools: [{ function_declarations: [extractGraphFunction] }],
      tool_config: {
        function_calling_config: { mode: "ANY", allowed_function_names: ["extract_graph"] },
      },
      generationConfig: { temperature: 0, thinkingConfig: { thinkingBudget: 0 } },
    };

    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        const response = await fetchImpl(
          `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
              "x-goog-api-key": permanentCredential,
            },
            body: JSON.stringify(providerBody),
            signal: AbortSignal.timeout(7000),
          },
        );
        if (response.status === 429 && attempt < 2) {
          await sleep(500 * 2 ** attempt);
          continue;
        }
        if (response.status === 429) {
          return jsonResponse(429, { status: "rejected", code: "rateLimited" });
        }
        if (!response.ok) {
          return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
        }

        const patch = patchFromProviderResponse(await response.json());
        if (!patch) {
          return jsonResponse(502, { status: "rejected", code: "invalidProviderResponse" });
        }
        let completion;
        for (let completionAttempt = 0; completionAttempt < 3; completionAttempt += 1) {
          try {
            completion = await completeExtraction({
              id: cacheKey,
              inputHash,
              ownerToken,
              patch,
              expiresAt: Math.floor(now() / 1000) + 7 * 24 * 60 * 60,
            });
            break;
          } catch {
            if (completionAttempt === 2) {
              return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
            }
            await sleep(100 * 2 ** completionAttempt);
          }
        }
        const normalizedCompletedPatch = normalizePatch(completion.patch);
        if (completion.status === "completed" && validPatch(normalizedCompletedPatch)) {
          return jsonResponse(200, { patch: normalizedCompletedPatch });
        }
        if (completion.status === "pending") {
          return jsonResponse(409, {
            status: "rejected",
            code: "inProgress",
            retryAfterMs: completion.retryAfterMs,
          });
        }
        if (completion.status === "mismatch") {
          return jsonResponse(409, { status: "rejected", code: "requestIdReused" });
        }
        return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
      } catch {
        if (attempt < 2) {
          await sleep(500 * 2 ** attempt);
          continue;
        }
        return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
      }
    }

    return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
  }

  return guardHandler("extract-graph", handle, () =>
    jsonResponse(503, { status: "rejected", code: "providerUnavailable" }),
  );
}

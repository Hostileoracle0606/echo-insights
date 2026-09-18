import { extractGraphFunction, granularPrompt, wikiPrompt } from "./prompts.mjs";

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

function boundedString(value, maxLength, { allowEmpty = false } = {}) {
  return typeof value === "string" &&
    value.length <= maxLength &&
    (allowEmpty || value.trim().length > 0);
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
    if (entity.description != null && !boundedString(entity.description, 1000, { allowEmpty: true })) {
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

function validRequest(body) {
  return (
    body &&
    boundedString(body.turnId, 100) &&
    boundedString(body.extractorVersion, 100) &&
    boundedString(body.text, 50000) &&
    body.text.trim().length >= 6 &&
    (body.mode === "wiki" || body.mode === "granular") &&
    validContext(body.context)
  );
}

function buildUserMessage(text, context) {
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

  return `EXISTING ENTITIES (reuse these spellings for the same thing):
${entities}

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
    if (entity.description != null && typeof entity.description !== "string") return false;
    if (entity.metadata != null && (typeof entity.metadata !== "object" || Array.isArray(entity.metadata))) {
      return false;
    }
    if (
      entity.questions != null &&
      (!Array.isArray(entity.questions) || entity.questions.some((question) => typeof question !== "string"))
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
  return true;
}

function patchFromProviderResponse(payload) {
  const parts = payload?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return null;
  for (const part of parts) {
    const call = part?.functionCall;
    if (call?.name === "extract_graph" && validPatch(call.args)) {
      return {
        entities: call.args.entities,
        relations: call.args.relations,
        supersedes: call.args.supersedes ?? [],
      };
    }
  }
  return null;
}

export function createExtractGraphHandler({
  supabaseUrl,
  publishableKey,
  getPermanentCredential,
  getCachedPatch,
  putCachedPatch,
  fetchImpl,
  model = "gemini-2.5-flash",
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
}) {
  return async function handle(event) {
    const userId = authorizedUserId(event);
    if (!userId) return jsonResponse(401, { error: "unauthorized" });

    const authorization = bearerAuthorization(event?.headers);
    if (!authorization) return jsonResponse(401, { error: "unauthorized" });

    const notebookId = notebookIdFrom(event);
    const body = parseBody(event);
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

    const cacheKey = `${userId}:${notebookId}:${body.turnId}:${body.extractorVersion}`;
    try {
      const cached = await getCachedPatch(cacheKey);
      if (validPatch(cached)) return jsonResponse(200, { patch: cached });
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    let permanentCredential;
    try {
      permanentCredential = (await getPermanentCredential()).trim();
      if (!permanentCredential) throw new Error("Gemini credential is empty");
    } catch {
      return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
    }

    const providerBody = {
      system_instruction: {
        parts: [{ text: body.mode === "wiki" ? wikiPrompt : granularPrompt }],
      },
      contents: [{ role: "user", parts: [{ text: buildUserMessage(body.text, body.context) }] }],
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
        try {
          await putCachedPatch(cacheKey, patch);
        } catch {
          return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
        }
        return jsonResponse(200, { patch });
      } catch {
        if (attempt < 2) {
          await sleep(500 * 2 ** attempt);
          continue;
        }
        return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
      }
    }

    return jsonResponse(503, { status: "rejected", code: "providerUnavailable" });
  };
}

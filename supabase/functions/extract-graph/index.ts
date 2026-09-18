import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const SYSTEM = `You are a knowledge graph builder for a personal voice journal.

EXTRACT ONLY NAMED ENTITIES — proper nouns the user explicitly identifies by a distinct name.

Capture:
- specific people (Alex, Dr. Patel, Grandma Rose)
- specific places (Brooklyn, Mt. Fuji, Blue Bottle on 4th, the Allen Library)
- specific organizations (Stripe, MIT, the Sierra Club)
- named projects (Project Mercury, the Atlas migration)
- named events (Coachella, Maya's wedding, Q3 review)
- named products or works (MacBook Pro, Dune: Part Two)
- types: person | place | organization | project | event | object | other

DO NOT extract:
- common nouns or generic things ("the meeting", "a coffee", "my laptop", "the gym")
- emotions, moods, or abstract concepts ("happiness", "stress", "freedom", "burnout")
- pronouns ("he", "she", "it", "they") — only the named referent if known
- generic role/relationship words alone ("my boss", "a friend", "a coworker") — extract only when paired with a name (e.g. "my boss Maya" → entity "Maya", role "boss" in metadata)
- adjectives, verbs, or actions

If the utterance contains no named entities, return an empty entities list and an empty relations list — silence is correct.

Also extract:
- relations BETWEEN named entities (short snake_case verb phrases like "works_with", "lives_in", "happened_at", "founded", "attended")
- metadata on named entities (dates, roles, locations, durations) — only when clearly stated

Inspect the whole context before planning a follow-up: existing entities, existing relations, recent entries, open follow-ups, graph gaps, thin entities, graph stats, and the new utterance.

Use the entity NAMES as ids in relations (the host will slugify). Reuse exact names from the existing graph when the same entity is referenced.`;

const FOLLOW_UP_RULES = `Follow-up rules:
- Ask only if the answer would materially improve the graph.
- Prioritize important thin entities, graph gaps, missing relation context, and important entities mentioned now.
- Do not ask for data already captured in the utterance, graph, recent entries, or open follow-ups.
- Do not repeat or closely paraphrase recent or open follow-up questions.
- Avoid generic prompts like "what kind of", "tell me more", or "can you elaborate" unless tied to a specific missing graph fact.
- Ask one short, warm, specific question under 20 words.
- If no useful graph-improving follow-up exists, return followUp.question as "", reason as "No material graph gap found.", and targetEntityNames as [].`;

interface GraphEntity {
  name: string;
  type: string;
  description?: string;
  metadata?: Record<string, unknown>;
  relationCount?: number;
  mentionCount?: number;
  lastMentionedAt?: string;
}

interface GraphRelation {
  source: string;
  target: string;
  label: string;
  metadata?: Record<string, unknown>;
}

interface RecentEntry {
  id?: string;
  text?: string;
  transcript?: string;
  summary?: string;
  createdAt?: string;
  date?: string;
  timestamp?: string;
  entityNames?: string[];
  entities?: string[];
  followUpQuestion?: string;
  followUp?:
    | string
    | {
        question?: string;
        reason?: string;
        targetEntityNames?: string[];
        answered?: boolean;
        createdAt?: string;
      };
}

interface ConversationTurn {
  role: string;
  text: string;
}

interface OpenFollowUp {
  question: string;
  reason?: string;
  targetEntityNames?: string[];
  createdAt?: string;
  status?: string;
}

interface GraphGap {
  name?: string;
  entityName?: string;
  targetEntityName?: string;
  type?: string;
  description?: string;
  reason?: string;
  missing?: string;
  importance?: string | number;
  relationHint?: string;
  degree?: number;
  mentionCount?: number;
  lastMentionedAt?: string;
}

interface GraphStats {
  entityCount?: number;
  relationCount?: number;
  thinEntityCount?: number;
  openFollowUpCount?: number;
  recentEntryCount?: number;
  topEntityNames?: string[];
  [key: string]: unknown;
}

interface ClientContext {
  existingEntities?: GraphEntity[];
  existingRelations?: GraphRelation[];
  recentEntries?: RecentEntry[];
  recentConversation?: ConversationTurn[];
  openFollowUps?: OpenFollowUp[];
  graphGaps?: GraphGap[];
  thinEntities?: GraphGap[];
  graphStats?: GraphStats;
  answeringFollowUp?: OpenFollowUp;
}

interface Body {
  text: string;
  existingEntities?: GraphEntity[];
  existingRelations?: GraphRelation[];
  recentEntries?: RecentEntry[];
  recentConversation?: ConversationTurn[];
  openFollowUps?: OpenFollowUp[];
  graphGaps?: GraphGap[];
  thinEntities?: GraphGap[];
  graphStats?: GraphStats;
  answeringFollowUp?: OpenFollowUp;
  context?: ClientContext;
}

interface ExtractGraphResult {
  entities: Array<{
    name: string;
    type: string;
    description?: string;
    metadata?: Record<string, string>;
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string>;
  }>;
  followUp: {
    question: string;
    reason: string;
    targetEntityNames: string[];
  };
}

const emptyResult = (): ExtractGraphResult => ({
  entities: [],
  relations: [],
  followUp: { question: "", reason: "", targetEntityNames: [] },
});

const cleanText = (value: unknown, maxLength = 300): string => {
  if (typeof value !== "string") return "";
  const cleaned = value.replace(/\s+/g, " ").trim();
  return cleaned.length > maxLength ? `${cleaned.slice(0, maxLength - 1)}...` : cleaned;
};

const formatValue = (value: unknown): string => {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return cleanText(value, 120);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value))
    return cleanText(value.map(formatValue).filter(Boolean).join(", "), 160);
  if (typeof value === "object") return cleanText(JSON.stringify(value), 180);
  return "";
};

const formatKeyValues = (value?: Record<string, unknown>): string => {
  if (!value) return "";
  return Object.entries(value)
    .map(([key, raw]) => {
      const formatted = formatValue(raw);
      return formatted ? `${key}: ${formatted}` : "";
    })
    .filter(Boolean)
    .join("; ");
};

const formatList = <T>(
  items: T[] | undefined,
  limit: number,
  render: (item: T) => string,
): string => {
  const rows = (items ?? []).slice(0, limit).map(render).filter(Boolean);
  return rows.length ? rows.join("\n") : "(none provided)";
};

const formatEntity = (entity: GraphEntity): string => {
  const details = [
    entity.description ? `description: ${cleanText(entity.description, 180)}` : "",
    entity.relationCount !== undefined ? `relations: ${entity.relationCount}` : "",
    entity.mentionCount !== undefined ? `mentions: ${entity.mentionCount}` : "",
    entity.lastMentionedAt ? `lastMentioned: ${cleanText(entity.lastMentionedAt, 60)}` : "",
    formatKeyValues(entity.metadata) ? `metadata: ${formatKeyValues(entity.metadata)}` : "",
  ]
    .filter(Boolean)
    .join("; ");

  return `- ${entity.name} (${entity.type})${details ? ` - ${details}` : ""}`;
};

const formatRelation = (relation: GraphRelation): string => {
  const metadata = formatKeyValues(relation.metadata);
  return `- ${relation.source} --${relation.label}--> ${relation.target}${metadata ? ` - ${metadata}` : ""}`;
};

const formatRecentEntry = (entry: RecentEntry): string => {
  const date = cleanText(entry.createdAt ?? entry.date ?? entry.timestamp, 80);
  const body = cleanText(entry.summary ?? entry.text ?? entry.transcript, 320);
  const followUp = typeof entry.followUp === "string" ? entry.followUp : entry.followUp?.question;
  const priorQuestion = cleanText(entry.followUpQuestion ?? followUp, 160);
  const entityNames = entry.entityNames ?? entry.entities;
  const entities = entityNames?.length ? ` | entities: ${entityNames.join(", ")}` : "";
  const question = priorQuestion ? ` | prior follow-up: ${priorQuestion}` : "";
  return `- ${date ? `[${date}] ` : ""}${body || "(no text provided)"}${entities}${question}`;
};

const formatConversationTurn = (turn: ConversationTurn): string => {
  const role = cleanText(turn.role, 40) || "unknown";
  const text = cleanText(turn.text, 240);
  return `- ${role}: ${text || "(empty)"}`;
};

const formatOpenFollowUp = (followUp: OpenFollowUp): string => {
  const details = [
    followUp.reason ? `reason: ${cleanText(followUp.reason, 180)}` : "",
    followUp.targetEntityNames?.length ? `targets: ${followUp.targetEntityNames.join(", ")}` : "",
    followUp.status ? `status: ${cleanText(followUp.status, 60)}` : "",
    followUp.createdAt ? `created: ${cleanText(followUp.createdAt, 60)}` : "",
  ]
    .filter(Boolean)
    .join("; ");
  return `- ${cleanText(followUp.question, 180)}${details ? ` - ${details}` : ""}`;
};

const formatGraphGap = (gap: GraphGap): string => {
  const name = gap.entityName ?? gap.targetEntityName ?? gap.name ?? "unnamed";
  const details = [
    gap.type ? `type: ${cleanText(gap.type, 60)}` : "",
    gap.description ? `description: ${cleanText(gap.description, 160)}` : "",
    gap.missing ? `missing: ${cleanText(gap.missing, 160)}` : "",
    gap.reason ? `reason: ${cleanText(gap.reason, 180)}` : "",
    gap.importance !== undefined ? `importance: ${gap.importance}` : "",
    gap.relationHint ? `relationHint: ${cleanText(gap.relationHint, 100)}` : "",
    gap.degree !== undefined ? `degree: ${gap.degree}` : "",
    gap.mentionCount !== undefined ? `mentions: ${gap.mentionCount}` : "",
    gap.lastMentionedAt ? `lastMentioned: ${cleanText(gap.lastMentionedAt, 60)}` : "",
  ]
    .filter(Boolean)
    .join("; ");
  return `- ${name}${details ? ` - ${details}` : ""}`;
};

const buildUserMessage = (body: Body): string => {
  const context = body.context ?? {};
  const existingEntities = context.existingEntities ?? body.existingEntities ?? [];
  const existingRelations = context.existingRelations ?? body.existingRelations ?? [];
  const recentEntries = context.recentEntries ?? body.recentEntries ?? [];
  const recentConversation = context.recentConversation ?? body.recentConversation ?? [];
  const openFollowUps = context.openFollowUps ?? body.openFollowUps ?? [];
  const graphGaps = context.graphGaps ?? body.graphGaps ?? [];
  const thinEntities = context.thinEntities ?? body.thinEntities ?? [];
  const graphStats = context.graphStats ?? body.graphStats;
  const answeringFollowUp = context.answeringFollowUp ?? body.answeringFollowUp;

  return `GRAPH STATS:
${formatKeyValues(graphStats) || "(none provided)"}

EXISTING GRAPH - TOP ENTITIES:
${formatList(existingEntities, 40, formatEntity)}

EXISTING GRAPH - RECENT OR IMPORTANT RELATIONS:
${formatList(existingRelations, 50, formatRelation)}

RECENT JOURNAL ENTRIES:
${formatList(recentEntries, 8, formatRecentEntry)}

RECENT CONVERSATION WITH THE AGENT:
${formatList(recentConversation, 8, formatConversationTurn)}

OPEN FOLLOW-UP QUESTIONS:
${formatList(openFollowUps, 12, formatOpenFollowUp)}

QUESTION THE USER MAY BE ANSWERING NOW:
${answeringFollowUp ? formatOpenFollowUp(answeringFollowUp) : "(none provided)"}

GRAPH GAPS:
${formatList(graphGaps, 12, formatGraphGap)}

THIN ENTITIES:
${formatList(thinEntities, 12, formatGraphGap)}

${FOLLOW_UP_RULES}

NEW UTTERANCE:
"""${body.text}"""`;
};

const normalizeResult = (value: Partial<ExtractGraphResult>): ExtractGraphResult => {
  const followUp = value.followUp ?? emptyResult().followUp;
  return {
    entities: Array.isArray(value.entities) ? value.entities : [],
    relations: Array.isArray(value.relations) ? value.relations : [],
    followUp: {
      question: typeof followUp.question === "string" ? followUp.question : "",
      reason: typeof followUp.reason === "string" ? followUp.reason : "",
      targetEntityNames: Array.isArray(followUp.targetEntityNames)
        ? followUp.targetEntityNames.filter((name): name is string => typeof name === "string")
        : [],
    },
  };
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const body = (await req.json()) as Body;
    const { text } = body;

    // ── Auth preamble (verify_jwt = true ensures a valid JWT) ──────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "missing authorization" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const supabaseUserClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const {
      data: { user },
      error: userError,
    } = await supabaseUserClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "invalid session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Optional notebook_id ownership check — if provided, verify the
    // user owns it. The client will pass this once Task 10 lands.
    const notebookId: string | undefined =
      ((body as Record<string, unknown>).notebook_id as string | undefined) ??
      ((body as Record<string, unknown>).notebookId as string | undefined);
    if (notebookId) {
      const { data: notebook, error: nbErr } = await supabaseUserClient
        .from("notebooks")
        .select("id")
        .eq("id", notebookId)
        .single();
      if (nbErr || !notebook) {
        return new Response(JSON.stringify({ error: "notebook not found" }), {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }
    // ── End auth preamble ──────────────────────────────────────────

    if (!text || text.trim().length < 2) {
      return new Response(JSON.stringify(emptyResult()), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const GROQ_API_KEY = Deno.env.get("GROQ_API_KEY");
    if (!GROQ_API_KEY) throw new Error("GROQ_API_KEY not configured");

    const tools = [
      {
        type: "function",
        function: {
          name: "update_graph",
          description: "Return entities, relations, and a follow-up object.",
          parameters: {
            type: "object",
            properties: {
              entities: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    type: {
                      type: "string",
                      enum: [
                        "person",
                        "place",
                        "organization",
                        "project",
                        "event",
                        "object",
                        "other",
                      ],
                    },
                    description: { type: "string" },
                    metadata: { type: "object", additionalProperties: { type: "string" } },
                  },
                  required: ["name", "type"],
                  additionalProperties: false,
                },
              },
              relations: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    source: { type: "string" },
                    target: { type: "string" },
                    label: { type: "string" },
                    metadata: { type: "object", additionalProperties: { type: "string" } },
                  },
                  required: ["source", "target", "label"],
                  additionalProperties: false,
                },
              },
              followUp: {
                type: "object",
                properties: {
                  question: {
                    type: "string",
                    description:
                      "A warm, specific follow-up question, or an empty string when no useful question exists.",
                  },
                  reason: {
                    type: "string",
                    description:
                      "The missing graph fact this would fill, or why no question is needed.",
                  },
                  targetEntityNames: { type: "array", items: { type: "string" } },
                },
                required: ["question", "reason", "targetEntityNames"],
                additionalProperties: false,
              },
            },
            required: ["entities", "relations", "followUp"],
            additionalProperties: false,
          },
        },
      },
    ];

    const userMsg = buildUserMessage(body);

    const resp = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${GROQ_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "llama-3.3-70b-versatile",
        messages: [
          { role: "system", content: SYSTEM },
          { role: "user", content: userMsg },
        ],
        tools,
        tool_choice: { type: "function", function: { name: "update_graph" } },
        temperature: 0.4,
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error("Groq error", resp.status, errText);
      if (resp.status === 429) {
        return new Response(
          JSON.stringify({ error: "Rate limit exceeded. Please wait a moment." }),
          {
            status: 429,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }
      if (resp.status === 402) {
        return new Response(
          JSON.stringify({
            error: "AI credits exhausted. Add credits in Settings > Workspace > Usage.",
          }),
          {
            status: 402,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }
      return new Response(JSON.stringify({ error: "AI request failed" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const data = await resp.json();
    const call = data.choices?.[0]?.message?.tool_calls?.[0];
    let parsed: ExtractGraphResult = emptyResult();
    if (call?.function?.arguments) {
      try {
        parsed = normalizeResult(JSON.parse(call.function.arguments));
      } catch (e) {
        console.error("parse fail", e);
      }
    }

    return new Response(JSON.stringify(parsed), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("extract-graph error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Unknown" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

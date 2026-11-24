import { z } from "zod";

/**
 * Shared types and response handling for graph extraction.
 *
 * The extractor itself (prompts, Gemini function declaration, the model call
 * and its credential) runs server-side in `infra/lambda/extract-graph`, behind
 * `POST /v1/notebooks/{notebookId}/extractions` on the Notebook Runtime. The
 * web app reaches it through `extraction-runtime-http.ts`, exactly as the
 * Flutter app does, so no provider key is ever present in the browser.
 *
 * What stays here:
 *  - the context types the web app compiles per turn;
 *  - `buildUserMessage`, which renders that context the way the runtime does
 *    and is used by `compileExtractionContext` to measure the token budget;
 *  - `parseExtractionPatch`, which validates the runtime's patch and applies
 *    the client-side noise filter.
 */

export interface GraphEntity {
  /** Durable entity id (slug). Sent to the runtime so relations can reference it. */
  id?: string;
  name: string;
  type: string;
  description?: string;
  metadata?: Record<string, unknown>;
  relationCount?: number;
  mentionCount?: number;
  lastMentionedAt?: string;
}

export interface GraphRelation {
  /** Optional stable id. Required for `supersedes` to be referenceable; absent for legacy callers. */
  id?: string;
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

export interface ConversationTurn {
  role: "user" | "assistant";
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

export type EntityCoverage = "thin" | "developing" | "rich";

export interface FocusEntity {
  name: string;
  type: string;
  wordsRecorded: number;
  wordsRemaining: number;
  mentionCount?: number;
  description?: string;
  coverage?: EntityCoverage;
}

export interface PreviouslyAsked {
  question: string;
  targetEntityNames: string[];
  askedAt: string;
}

export interface BridgingCandidate {
  a: { name: string; type: string };
  b: { name: string; type: string };
  reason?: string;
}

export interface SessionState {
  isSessionStart: boolean;
  /** ISO timestamp of the most recent prior entry, if any. */
  lastEntryAt?: string;
  /** Number of utterances exchanged in the current session so far. */
  turnsThisSession?: number;
}

/**
 * Everything the extraction prompt actually consumes — and nothing else.
 *
 * This used to carry graph statistics, gaps, focus entities, bridging
 * candidates, previously-asked questions and recent entries. None of them
 * reached the model: `buildUserMessage` never read them. They are removed
 * rather than left to cost serialization on every turn. The dialogue-planning
 * fields that genuinely need that data live on the Gemini Live tool surface
 * (`get_graph_summary`), not here.
 */
export interface ClientContext {
  existingEntities?: GraphEntity[];
  existingRelations?: GraphRelation[];
  recentConversation?: ConversationTurn[];
  /** The open question this utterance is answering, when there is one. */
  answeringFollowUp?: OpenFollowUp;
  sessionState?: SessionState;
}

export interface ExtractGraphBody {
  /** The new utterance. The ONLY source from which new facts may be extracted. */
  text: string;
  existingEntities?: GraphEntity[];
  existingRelations?: GraphRelation[];
  recentConversation?: ConversationTurn[];
  answeringFollowUp?: OpenFollowUp;
  sessionState?: SessionState;
  context?: ClientContext;
}

export interface ExtractGraphResult {
  entities: Array<{
    name: string;
    type: string;
    description?: string;
    metadata?: Record<string, string>;
    /** Wiki-mode: per-entity question backlog. Empty in granular mode. */
    questions?: string[];
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string>;
  }>;
  /**
   * Ids of EXISTING RELATIONS the user just contradicted. The host clears
   * the corresponding relations by setting supersededAt = now. Empty (or
   * omitted) on most turns. Ids that don't match anything in state are
   * silently skipped — see processGraphUpdate / mergeExtraction.
   */
  supersedes?: string[];
  followUp: {
    question: string;
    reason: string;
    targetEntityNames: string[];
  };
}

export const emptyExtractionResult = (): ExtractGraphResult => ({
  entities: [],
  relations: [],
  supersedes: [],
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
  const idPrefix = relation.id ? `[${relation.id}] ` : "";
  return `- ${idPrefix}${relation.source} --${relation.label}--> ${relation.target}${metadata ? ` - ${metadata}` : ""}`;
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

const formatFocusEntity = (entity: FocusEntity): string => {
  const desc = entity.description ? `; description: ${cleanText(entity.description, 140)}` : "";
  const coverage = entity.coverage ? `; coverage: ${entity.coverage}` : "";
  return `- ${entity.name} (${entity.type}) - wordsRecorded: ${entity.wordsRecorded}; wordsRemaining: ${entity.wordsRemaining}; mentions: ${entity.mentionCount ?? 0}${coverage}${desc}`;
};

const formatPreviouslyAsked = (asked: PreviouslyAsked): string => {
  const targets = asked.targetEntityNames.length ? ` [${asked.targetEntityNames.join(", ")}]` : "";
  return `- "${cleanText(asked.question, 160)}"${targets}`;
};

const formatBridgingCandidate = (c: BridgingCandidate): string => {
  const reason = c.reason ? ` — ${cleanText(c.reason, 80)}` : "";
  return `- ${c.a.name} (${c.a.type}) ↔ ${c.b.name} (${c.b.type})${reason}`;
};

/**
 * Safety limits, not the budget. compileExtractionContext bounds the prompt in
 * measured model tokens; these caps only stop a pathological caller from
 * handing the formatter an unbounded list.
 */
export const MAX_PROMPT_ENTITIES = 40;
export const MAX_PROMPT_RELATIONS = 60;
export const MAX_PROMPT_TURNS = 8;

/**
 * Slim user message: only what an NER pass actually needs.
 *
 * - top 20 existing entities so the model can reuse spellings + skip dupes
 * - last 4 conversation turns so pronouns ("she", "that place") resolve
 *
 * Everything else (graph stats, gaps, focus entities, follow-ups, bridging,
 * DIALOGUE_POLICY) was useful when this same call also drove dialogue. In
 * Branch B it's dead weight.
 */
export const buildUserMessage = (body: ExtractGraphBody): string => {
  const context = body.context ?? {};
  const existingEntities = context.existingEntities ?? body.existingEntities ?? [];
  const existingRelations = context.existingRelations ?? body.existingRelations ?? [];
  const recentConversation = context.recentConversation ?? body.recentConversation ?? [];
  const answering = context.answeringFollowUp ?? body.answeringFollowUp;
  // Item counts below are safety limits only. The real bound is the token
  // budget applied by compileExtractionContext before this is called.
  const answeringSection = answering
    ? `\n\nANSWERING THIS OPEN QUESTION (the new utterance is its answer):\n${formatOpenFollowUp(answering)}`
    : "";

  return `EXISTING ENTITIES (use these spellings when the user refers to the same thing):
${formatList(existingEntities, MAX_PROMPT_ENTITIES, formatEntity)}

EXISTING RELATIONS (each prefixed with its [id] — use these IDs verbatim in supersedes when the user contradicts the relation):
${formatList(existingRelations, MAX_PROMPT_RELATIONS, formatRelation)}

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these turns):
${formatList(recentConversation, MAX_PROMPT_TURNS, formatConversationTurn)}${answeringSection}

NEW UTTERANCE:
"""${body.text}"""`;
};

const entityPatchSchema = z.object({
  name: z.string().min(1).describe("Entity name as it appears in the utterance."),
  type: z
    .enum([
      "person",
      "place",
      "organization",
      "project",
      "event",
      "activity",
      "concept",
      "emotion",
      "other",
    ])
    .describe("Named-entity category."),
  description: z.string().optional(),
  metadata: z.record(z.string()).optional(),
  questions: z
    .array(z.string())
    .optional()
    .describe("Wiki-mode only: 2-4 lines of questioning Lumen could pursue about this entity."),
});

const relationPatchSchema = z.object({
  source: z.string().min(1).describe("Source entity name (host slugifies)."),
  target: z.string().min(1).describe("Target entity name (host slugifies)."),
  label: z.string().min(1).describe("Snake_case verb phrase, e.g. works_with."),
  metadata: z.record(z.string()).optional(),
});

const graphPatchSchema = z.object({
  entities: z.array(entityPatchSchema),
  relations: z.array(relationPatchSchema),
  supersedes: z.array(z.string().min(1)).optional(),
});

type GraphPatch = z.infer<typeof graphPatchSchema>;

/**
 * Client-side safety net: mode-agnostic stoplist for entity names the model
 * sometimes leaks despite explicit prompt rules. We dedupe against this AFTER
 * zod validation so we don't need to thread it through the LLM round-trip.
 *
 * Each entry is the lowercase, stripped surface form ("I", "lumen") that
 * would never anchor a real wiki page or graph node. We compare on a
 * normalized key so the model can't sneak past with capitalization or
 * trailing punctuation.
 */
const NOISE_NAMES = new Set([
  "i",
  "me",
  "my",
  "mine",
  "you",
  "your",
  "yours",
  "we",
  "us",
  "our",
  "they",
  "them",
  "their",
  "happy",
  "sad",
  "tired",
  "stressed",
  "anxious",
  "angry",
  "excited",
  "fine",
  "ok",
  "okay",
  "today",
  "yesterday",
  "tomorrow",
  "morning",
  "afternoon",
  "evening",
  "night",
  "now",
  "later",
  "lumen",
]);

const normalizeName = (name: string): string =>
  name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9 ]+/g, "")
    .trim();

const filterNoise = (patch: GraphPatch): GraphPatch => {
  const kept = patch.entities.filter((e) => {
    const key = normalizeName(e.name);
    if (!key) return false;
    if (NOISE_NAMES.has(key)) return false;
    // Single-character names are almost always pronoun/transcription noise.
    if (key.length < 2) return false;
    return true;
  });
  const keptKeys = new Set(kept.map((e) => normalizeName(e.name)));
  // Drop relations whose endpoints don't survive the entity filter — but
  // keep relations whose endpoints reference EXISTING ENTITIES (not in this
  // patch). We can't validate those here, so trust the model on cross-patch
  // edges and only drop edges that point at noise we just removed.
  const droppedKeys = new Set(
    patch.entities.map((e) => normalizeName(e.name)).filter((k) => !keptKeys.has(k)),
  );
  const relations = patch.relations.filter(
    (r) => !droppedKeys.has(normalizeName(r.source)) && !droppedKeys.has(normalizeName(r.target)),
  );
  // supersedes carries opaque ids, not entity names — pass through.
  return { entities: kept, relations, supersedes: patch.supersedes };
};

const patchToResult = (patch: GraphPatch): ExtractGraphResult => ({
  entities: patch.entities.map((entity) => ({
    name: entity.name,
    type: entity.type,
    description: entity.description,
    metadata: entity.metadata,
    questions: entity.questions,
  })),
  relations: patch.relations.map((relation) => ({
    source: relation.source,
    target: relation.target,
    label: relation.label,
    metadata: relation.metadata,
  })),
  supersedes: patch.supersedes ?? [],
  followUp: { question: "", reason: "", targetEntityNames: [] },
});

/**
 * Validates a patch returned by the extraction runtime and converts it to the
 * shape the merge step consumes. Returns null when the patch is malformed.
 */
export function parseExtractionPatch(value: unknown): ExtractGraphResult | null {
  const validation = graphPatchSchema.safeParse(value);
  if (!validation.success) {
    console.error("[extractGraph] patch validation failed:", validation.error.format());
    return null;
  }
  return patchToResult(filterNoise(validation.data));
}

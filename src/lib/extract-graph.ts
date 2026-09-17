import { z } from "zod";

import type { ExtractionMode } from "./journal-types";

/**
 * Branch B extractor: silent NER over the user's transcript.
 *
 * Gemini Live owns the spoken conversation, so this call only needs to
 * return entities + relations. Runs on gemini-2.5-flash with thinking
 * DISABLED (thinkingBudget: 0) — the extractor is a tight NER pass over
 * short utterances, and reasoning chains would multiply latency without
 * improving entity precision. Latency, not depth-of-reasoning, is the
 * binding constraint at natural voice pacing.
 *
 * Migrated from Groq llama-3.3-70b-versatile to consolidate on the same
 * provider already running the live conversation — one fewer API key, one
 * fewer rate-limit ceiling to manage, and roughly half the per-session
 * cost. Trade-off: Gemini's base latency is a touch higher than Groq's
 * custom inference stack, but disabling thinking keeps it within budget.
 *
 * Two extraction modes (selected per-call by ExtractionMode):
 *  - "wiki":     entity must support a real line of questioning. Model is
 *                required to emit 2–4 follow-up questions per entity it
 *                returns; no questions = entity gets dropped. Result: a
 *                clean topical wiki, fewer nodes.
 *  - "granular": current behavior — extract any named entity, no question
 *                requirement. More signal, more noise.
 */
const WIKI_EXTRACTOR_PROMPT = `You are the editor of the user's personal wiki — built silently from their voice journal.

Your job is to decide which things in the user's utterance deserve their own wiki page. The bar is HIGH: a node only exists if it can anchor a real line of questioning that Lumen could pursue across multiple sessions to build a substantive page.

THE WIKI-PAGE TEST — apply to every candidate:
  Imagine the user comes back next week. Could you, as Lumen, ask 2–4 distinct, meaningful questions about this thing that would build a real page over time?
  - PASSES: "Maya" (How long have you known her? What's she like? Where did you meet?)
  - PASSES: "CS246" (What's the material? Who's teaching it? Why retaking?)
  - PASSES: "Project Atlas" (What problem? Who's on it? Where in its lifecycle?)
  - PASSES: "AI" — only if the user is genuinely reasoning about it as a topic. (What about AI bothers you? What sparked this thought?)
  - PASSES: "anxiety", "burnout", "imposter syndrome" — when the user names them as recurring patterns worth tracking across sessions. Type these as emotion.
  - PASSES: "running", "meditation", "journaling" — recurring behaviors the user reasons about. Type these as activity.
  - FAILS: "I" — there's no line of questioning ABOUT the user-as-pronoun. Their life is the wiki, not a node in it.
  - FAILS: "happy", "tired", "stressed" used as one-off mood words about a single moment — those are properties of moments, not topics. The line of questioning routes through what made you feel that way.
  - FAILS: "yesterday", "today", "this morning" — time words are coordinates, not topics.
  - FAILS: "85", numbers, generic adjectives — values, not topics.
  - FAILS: "Lumen" — the agent's own name. Never extract.
  - FAILS: transcription artifacts, slang misheard ("True Nub"), filler.

ENTITIES — what to return:
- Only return things that pass the wiki-page test.
- entity.name: surface form as the user said it.
- entity.type: one of person, place, organization, project, event, activity, concept, emotion, other.
  - activity: recurring behaviors the user reasons about (running, journaling, meditation).
  - concept: abstract topics the user treats as named things (AI, attachment_theory, behavioral_patterns).
  - emotion: named recurring emotional patterns (anxiety, burnout) — NOT one-off mood words.
  - other: only when nothing else fits. Avoid using this as a default.
- entity.description: only when the utterance gives a concrete, factual statement about the entity.
- entity.questions: 2–4 distinct lines of questioning Lumen could pursue. These should NOT be questions the user already answered in this utterance — they're the open threads. Phrase them as Lumen would actually ask them, warm and specific.
- Dedup against EXISTING ENTITIES — reuse the existing spelling.

CONTINUATIONS — preserve subjects across turns:
When RECENT CONVERSATION shows the agent just asked about an entity from EXISTING ENTITIES, and the user's reply continues that subject — pronouns ("she/he/it/they"), partial answer ("since freshman year"), or implicit reference ("the project", "that class") — INCLUDE that entity in \`entities\` using its existing spelling. The user's reply IS information about that entity even when they don't name it; without re-listing it, the journal loses the link to the entity's page.

Apply this whenever the user's turn:
  - directly answers the agent's last question about a known entity
  - elaborates on the prior subject without naming it
  - references the prior subject via pronoun or definite article

Do NOT apply when the user pivots to a new subject. The trigger is a Q-A pair about the same entity.

RELATIONS — keep the wiki connected. This is load-bearing. A wiki of disconnected pages is useless:
- Format: source --label--> target. label = snake_case phrase (e.g. simulates, contrasts_with, example_of, used_for, depends_on, part_of, related_to, mentioned_with, situated_at, occurred_during, involves, exhibits, enables).
- Endpoints must be entities — either ones you're returning now OR ones in EXISTING ENTITIES.
- AGGRESSIVELY CONNECT. For every entity in this turn, scan for an edge to:
  (a) every other entity in this turn,
  (b) every entity in EXISTING ENTITIES that the user is still talking about (resolved via RECENT CONVERSATION),
  (c) any prior entity the new one is a sibling/instance/component of.
- TARGET DENSITY: aim for at least one edge per new entity, ideally more. If you return N new entities and zero edges, you have failed unless every entity is a true orphan topic.
- WEAK-BUT-TRUE RELATIONS COUNT. Co-occurrence in the same thought IS a relation; use \`mentioned_with\` or \`related_to\` when no stronger label fits. A vague-but-grounded edge is better than no edge.
- Examples of valid weak relations:
  · "I went running with Maya in Brooklyn" → running--with-->Maya, running--at-->Brooklyn, Maya--in-->Brooklyn.
  · "I'm anxious about the Atlas demo" → anxiety--about-->Project_Atlas, Project_Atlas--has_event-->demo.
  · "CS246 reminds me of CS241" → CS246--related_to-->CS241.
- "Never invent facts" means don't fabricate specifics the user didn't say (don't guess Maya's job, don't make up a date). It does NOT mean refusing to record relations the user clearly implied by mentioning two things together.

SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in \`supersedes\`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

If the utterance contains nothing that passes the wiki-page test, return empty arrays. Better an empty turn than wiki bloat.
Never speak to the user. You are not the conversational agent.`;

const GRANULAR_EXTRACTOR_PROMPT = `You are a silent graph extractor for a voice journal.
Your job is to keep the user's knowledge graph CONNECTED. A fragmented graph (islands of nodes with no edges) is a failure mode — actively prevent it.

ENTITIES — extract from the NEW UTTERANCE:
- Proper nouns: people, places, projects, events, organizations (Maya, Brooklyn, Project Atlas).
- Concrete concepts the user names and reasons about (e.g. "AI", "technology", "behavioral patterns", "intelligence"). These are valid nodes when the user treats them as discrete things, not when they're filler.
- entity.type: one of person, place, organization, project, event, activity, concept, emotion, other.
  - activity: recurring behaviors ("running", "meditation", "journaling").
  - concept: abstract topics treated as named things ("AI", "behavioral_patterns").
  - emotion: named recurring emotional patterns ("anxiety", "burnout") — NOT one-off mood words.
  - "other" is a true fallback; use it only when nothing else fits.
- entity.description: only if the utterance gives a concrete fact about the entity; otherwise omit.
- Skip pronouns, generic time words ("today", "yesterday"), one-off mood words ("happy", "stressed" used to describe a single moment), and verbs.
- Dedup against EXISTING ENTITIES — reuse the existing spelling when the user is clearly referring to the same thing.

CONTINUATIONS — preserve subjects across turns:
When RECENT CONVERSATION shows the agent just asked about an entity from EXISTING ENTITIES, and the user's reply continues that subject — pronouns ("she/he/it/they"), partial answer ("since freshman year"), or implicit reference ("the project", "that class") — INCLUDE that entity in \`entities\` using its existing spelling. The user's reply IS information about that entity even when they don't name it; without re-listing it, the journal loses the link to the entity's page.

Apply this whenever the user's turn:
  - directly answers the agent's last question about a known entity
  - elaborates on the prior subject without naming it
  - references the prior subject via pronoun or definite article

Do NOT apply when the user pivots to a new subject. The trigger is a Q-A pair about the same entity.

RELATIONS — this is the most important part. Connect aggressively. Islands of nodes are a hard failure:
- Format: source --label--> target. label = snake_case phrase (e.g. simulates, contrasts_with, example_of, used_for, depends_on, part_of, related_to, mentioned_with, situated_at, occurred_during, involves, exhibits, enables).
- Endpoints must be entities — either ones you're returning now OR ones in EXISTING ENTITIES.
- FOR EVERY ENTITY in this turn, scan exhaustively for edges to:
  (a) every other entity in this turn (co-occurrence in the same thought is a relation),
  (b) every entity in EXISTING ENTITIES the user is still talking about (resolved via RECENT CONVERSATION),
  (c) parent/sibling/instance entities in EXISTING ENTITIES that the new one fits under.
- TARGET DENSITY: aim for at least one edge per new entity, ideally more. If you return N new entities and zero edges, you have failed unless every entity is a true orphan topic.
- WEAK-BUT-TRUE RELATIONS COUNT. When two entities show up in the same utterance and you can't think of a stronger label, emit \`mentioned_with\` or \`related_to\`. The graph being WIRED is worth more than every edge being maximally precise.
- Examples:
  · "AI can simulate intelligence" with \`AI\`, \`intelligence\`, \`technology\` already known → AI--simulates-->intelligence, AI--is_a-->technology.
  · "people exhibit behavioral patterns" → people--exhibits-->behavioral_patterns.
  · "I went running with Maya in Brooklyn" → running--with-->Maya, running--at-->Brooklyn, Maya--in-->Brooklyn.
  · "I'm anxious about the Atlas demo" → anxiety--about-->Project_Atlas, Project_Atlas--has_event-->demo.
  · "CS246 reminds me of CS241" → CS246--related_to-->CS241.
  · user reasons about a concept that subsumes an existing one → existing--example_of-->new_concept.
- "Never invent facts the user didn't imply" means don't fabricate specifics they didn't say (don't guess Maya's age, don't make up an address). It does NOT mean refusing to record relations they clearly implied by mentioning two things in the same breath.

SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in \`supersedes\`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

Return empty arrays only when the utterance has no extractable entities — small talk, hesitations, yes/no answers, filler tokens.
Never speak to the user. You are not the conversational agent.`;

export interface GraphEntity {
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

const emptyResult = (): ExtractGraphResult => ({
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

// Gemini's function_declarations accept an OpenAPI-flavored subset of JSON
// Schema. We deliberately omit `additionalProperties: false` — Gemini's
// validator doesn't reliably honor it and rejects schemas that include it
// at deeper nesting levels. Zod re-validates the model's output downstream
// anyway, so closure happens at the parse boundary, not in the schema itself.
const extractGraphFunction = {
  name: "extract_graph",
  description: "Return entities and relations mentioned in NEW UTTERANCE.",
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
                "activity",
                "concept",
                "emotion",
                "other",
              ],
            },
            description: { type: "string" },
            metadata: { type: "object" },
            questions: {
              type: "array",
              items: { type: "string" },
              description:
                "Wiki-mode only: 2-4 follow-up questions Lumen could ask about this entity. Omit in granular mode.",
            },
          },
          required: ["name", "type"],
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
            metadata: { type: "object" },
          },
          required: ["source", "target", "label"],
        },
      },
      supersedes: {
        type: "array",
        items: { type: "string" },
        description:
          "Ids of relations from EXISTING RELATIONS (the [bracketed] prefix) that the user just contradicted. Empty array if nothing contradicted. Use the EXACT id from the brackets — never invent one.",
      },
    },
    required: ["entities", "relations"],
  },
};

// Abort-aware sleep used by the 429 retry loop. Resolves when the timer
// elapses or rejects with AbortError if the caller aborts mid-wait — so
// a newer sentence arriving during backoff still cancels cleanly.
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new DOMException("Aborted", "AbortError"));
      },
      { once: true },
    );
  });
}

export async function extractGraph(
  body: ExtractGraphBody,
  signal?: AbortSignal,
  mode: ExtractionMode = "wiki",
): Promise<ExtractGraphResult> {
  const text = body.text;
  const isSessionStart =
    body.sessionState?.isSessionStart ?? body.context?.sessionState?.isSessionStart ?? false;
  // Branch B: session-start no longer needs an extractor call (Gemini Live
  // handles the opening line). Skip the round trip entirely.
  if (isSessionStart) return emptyResult();
  if (!text || text.trim().length < 2) return emptyResult();

  const apiKey = import.meta.env.VITE_GEMINI_API_KEY?.trim();
  if (!apiKey) throw new Error("VITE_GEMINI_API_KEY is missing.");

  const userMsg = buildUserMessage(body);
  const systemPrompt = mode === "wiki" ? WIKI_EXTRACTOR_PROMPT : GRANULAR_EXTRACTOR_PROMPT;

  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent";
  const requestInit: RequestInit = {
    method: "POST",
    headers: {
      "x-goog-api-key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      system_instruction: { parts: [{ text: systemPrompt }] },
      contents: [{ role: "user", parts: [{ text: userMsg }] }],
      tools: [{ function_declarations: [extractGraphFunction] }],
      // mode: "ANY" + a single allowed function = forced tool call,
      // Gemini's equivalent of OpenAI's tool_choice: { type: "function" ... }.
      tool_config: {
        function_calling_config: {
          mode: "ANY",
          allowed_function_names: ["extract_graph"],
        },
      },
      generationConfig: {
        temperature: 0.2,
        // thinkingBudget: 0 disables Flash 2.5's reasoning trace. Without
        // this, the model emits hidden chain-of-thought tokens before the
        // tool call — fine for harder reasoning, fatal here: NER pacing
        // needs <1s round-trips and thinking adds 2-5s plus pay-per-token
        // hidden output that we never use.
        thinkingConfig: { thinkingBudget: 0 },
      },
    }),
    signal,
  };

  // Retry on 429 with exponential backoff (1s then 2s) — three attempts
  // total. Honors Retry-After when Gemini sends it, otherwise falls back
  // to the schedule. Most free-tier 429s clear within the next per-minute
  // window, so a short retry loop swallows the transient case without
  // surfacing a toast. After the loop, a persistent 429 falls through to
  // the existing error path below.
  const MAX_RETRIES = 2;
  let resp = await fetch(url, requestInit);
  for (let attempt = 1; resp.status === 429 && attempt <= MAX_RETRIES; attempt++) {
    const retryAfterRaw = resp.headers.get("Retry-After");
    const retryAfterSec = retryAfterRaw ? Number.parseInt(retryAfterRaw, 10) : Number.NaN;
    const delayMs =
      Number.isFinite(retryAfterSec) && retryAfterSec > 0
        ? retryAfterSec * 1000
        : 1000 * 2 ** (attempt - 1);
    console.warn(
      `[extractGraph] 429 — retrying in ${delayMs}ms (attempt ${attempt}/${MAX_RETRIES})`,
    );
    // Drain the body so the underlying connection can be reused on retry.
    await resp.text().catch(() => "");
    await sleep(delayMs, signal);
    resp = await fetch(url, requestInit);
  }

  if (!resp.ok) {
    const detail = await resp.text().catch(() => "");
    // Always log the full body to console — invaluable for diagnosing the
    // intermittent 400s (safety filter blocks, schema rejections, malformed
    // utterances). Truncated detail in toasts is not enough.
    console.error("[extractGraph] HTTP error", {
      status: resp.status,
      utterance: text.slice(0, 240),
      body: detail,
    });
    if (resp.status === 429) {
      throw new Error("Rate limit exceeded. Please wait a moment.");
    }
    if (resp.status === 401 || resp.status === 403) {
      throw new Error("Gemini rejected the API key. Check VITE_GEMINI_API_KEY.");
    }
    if (resp.status === 400) {
      // Don't break the whole graph for a single bad utterance — log + skip.
      // Common causes: safety-filter false positives, transcripts with rare
      // unicode, occasional schema-validation hiccups when the utterance
      // shape sits at an awkward edge of the function-call format.
      return emptyResult();
    }
    throw new Error(`Gemini request failed (${resp.status}): ${detail.slice(0, 240)}`);
  }

  const data = await resp.json();
  // Gemini puts the tool call inside candidates[0].content.parts[*].functionCall.
  // Unlike Groq/OpenAI, args is already a parsed object — no JSON.parse needed.
  // The model can also return text alongside the call (or, on safety blocks,
  // omit the call entirely with finishReason: "SAFETY"); we tolerate both by
  // searching parts for the first matching functionCall and falling back to
  // an empty result rather than throwing.
  const parts: Array<{ functionCall?: { name?: string; args?: unknown } }> =
    data.candidates?.[0]?.content?.parts ?? [];
  const fnCall = parts.find((p) => p.functionCall?.name === "extract_graph")?.functionCall;
  if (!fnCall?.args) {
    console.warn("[extractGraph] no functionCall in response", data);
    return emptyResult();
  }

  const validation = graphPatchSchema.safeParse(fnCall.args);
  if (!validation.success) {
    console.error("[extractGraph] zod validation failed:", validation.error.format(), fnCall.args);
    return emptyResult();
  }

  return patchToResult(filterNoise(validation.data));
}

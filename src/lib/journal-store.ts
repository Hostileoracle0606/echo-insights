import type {
  AskedQuestion,
  Entity,
  ExtractionMode,
  JournalEntry,
  JournalState,
  Relation,
  FollowUp,
} from "./journal-types";

const KEY = "lumen.journal.v1";
const MODE_KEY = "lumen.extractionMode.v1";

/**
 * Default mode = "wiki". The product direction is curated/topical
 * extraction; granular is the opt-in for users who want raw capture.
 */
export const DEFAULT_EXTRACTION_MODE: ExtractionMode = "wiki";

export function loadExtractionMode(): ExtractionMode {
  if (typeof window === "undefined") return DEFAULT_EXTRACTION_MODE;
  const value = localStorage.getItem(MODE_KEY);
  return value === "granular" || value === "wiki" ? value : DEFAULT_EXTRACTION_MODE;
}

export function saveExtractionMode(mode: ExtractionMode) {
  if (typeof window === "undefined") return;
  localStorage.setItem(MODE_KEY, mode);
}

/** Most-recent N agent questions retained in state for repetition checks. */
export const ASKED_QUESTIONS_CAP = 30;

const EMPTY: JournalState = {
  entries: [],
  entities: {},
  relations: {},
  followUps: [],
  askedQuestions: [],
};

export function loadState(): JournalState {
  if (typeof window === "undefined") return EMPTY;
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return EMPTY;
    const parsed = JSON.parse(raw) as JournalState;
    // The "object" entity type was deprecated in favor of "other" — they were
    // visually and semantically redundant. Coerce legacy entities forward so
    // the type union and palette stay in sync with what's persisted.
    const entities = Object.fromEntries(
      Object.entries(parsed.entities ?? {}).map(([id, entity]) => [
        id,
        (entity as { type: string }).type === "object"
          ? { ...entity, type: "other" as const }
          : entity,
      ]),
    );
    return {
      entries: parsed.entries ?? [],
      entities,
      relations: parsed.relations ?? {},
      followUps: parsed.followUps ?? [],
      askedQuestions: parsed.askedQuestions ?? [],
    };
  } catch {
    return EMPTY;
  }
}

export function saveState(state: JournalState) {
  if (typeof window === "undefined") return;
  localStorage.setItem(KEY, JSON.stringify(state));
}

export function clearState() {
  if (typeof window === "undefined") return;
  localStorage.removeItem(KEY);
}

export function slugify(name: string): string {
  return name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 60) || `e-${Math.random().toString(36).slice(2, 8)}`;
}

export interface ExtractedPayload {
  entities: Array<{
    name: string;
    type: Entity["type"];
    description?: string;
    metadata?: Record<string, string | number | boolean>;
    /**
     * Wiki-mode only: lines of questioning Lumen can pursue about this
     * entity. Granular extractor returns this empty (or absent).
     */
    questions?: string[];
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string | number | boolean>;
  }>;
  /**
   * Ids of relations the user contradicted. mergeExtraction sets
   * supersededAt on each. Silently skips missing or already-superseded ids.
   */
  supersedes?: string[];
  followUp?: { question: string; reason: string; targetEntityNames: string[] };
}

/**
 * Cap on questions per entity. Wiki extractor typically returns 2–4 per
 * call, but across many merges they accumulate — without a cap the page
 * becomes unreadable. We dedup case-insensitively and keep the most
 * recent N so old questions roll off as new threads emerge.
 */
const MAX_QUESTIONS_PER_ENTITY = 8;

const mergeQuestions = (
  existing: string[] | undefined,
  incoming: string[] | undefined,
): string[] | undefined => {
  if (!existing?.length && !incoming?.length) return existing;
  const seen = new Set<string>();
  const merged: string[] = [];
  // Newer questions win on dedup so the model's latest framing is preserved.
  for (const q of [...(incoming ?? []), ...(existing ?? [])]) {
    const trimmed = q?.trim();
    if (!trimmed) continue;
    const key = trimmed.toLowerCase().replace(/[^a-z0-9 ]+/g, "");
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(trimmed);
    if (merged.length >= MAX_QUESTIONS_PER_ENTITY) break;
  }
  return merged.length ? merged : undefined;
};

export function mergeExtraction(
  prev: JournalState,
  text: string,
  payload: ExtractedPayload,
): { next: JournalState; entryId: string } {
  const now = new Date().toISOString();
  const entities = { ...prev.entities };
  const relations = { ...prev.relations };
  const followUps = [...prev.followUps];
  const askedQuestions = [...(prev.askedQuestions ?? [])];
  const entryEntityIds: string[] = [];
  const entryRelationIds: string[] = [];

  // entities
  const nameToId: Record<string, string> = {};
  for (const e of payload.entities ?? []) {
    if (!e?.name) continue;
    const id = slugify(e.name);
    nameToId[e.name.toLowerCase()] = id;
    const existing = entities[id];
    entities[id] = existing
      ? {
          ...existing,
          description: e.description || existing.description,
          metadata: { ...existing.metadata, ...(e.metadata ?? {}) },
          mentions: existing.mentions + 1,
          lastSeen: now,
          type: existing.type === "other" ? e.type : existing.type,
          questions: mergeQuestions(existing.questions, e.questions),
        }
      : {
          id,
          name: e.name,
          type: e.type ?? "other",
          description: e.description,
          metadata: e.metadata ?? {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
          questions: mergeQuestions(undefined, e.questions),
        };
    entryEntityIds.push(id);
  }

  // Track which entity ids the model explicitly returned in entities[] this
  // turn, so the implicit-touch pass below can avoid double-counting them.
  const explicitlyTaggedIds = new Set(Object.values(nameToId));

  // relations
  for (const r of payload.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    if (!src || !tgt || src === tgt) continue;
    const rid = `${src}__${r.label}__${tgt}`;
    if (!relations[rid]) {
      relations[rid] = {
        id: rid,
        source: src,
        target: tgt,
        label: r.label,
        metadata: r.metadata ?? {},
        createdAt: now,
      };
    } else {
      // Re-assertion of an existing relation. If it was previously
      // soft-superseded, the user has now affirmed it again — clear the
      // supersede so it returns to the graph view + export. This is the
      // self-healing path for false-positive supersedes.
      const { supersededAt: _ignored, ...rest } = relations[rid];
      relations[rid] = {
        ...rest,
        metadata: { ...rest.metadata, ...(r.metadata ?? {}) },
      };
    }
    entryRelationIds.push(rid);
  }

  // Backfill entry tagging for relation endpoints that resolve to existing
  // entities the model did NOT list in entities[] this turn. Catches the
  // pronoun-driven follow-up case: the user replies "she's been my best
  // friend since freshman year", the model emits Maya--known_since-->college
  // (binding Maya by name from EXISTING ENTITIES) but doesn't repeat Maya in
  // entities[]. Without this, the reply wouldn't show on Maya's detail page
  // even though her graph grew.
  const implicitlyTouchedIds = new Set<string>();
  for (const r of payload.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    for (const id of [src, tgt]) {
      if (!id) continue;
      if (explicitlyTaggedIds.has(id)) continue;
      if (implicitlyTouchedIds.has(id)) continue;
      const existing = entities[id];
      // Only bump entities that already existed before this turn — we don't
      // want to invent a new entity from a slugified relation endpoint.
      if (!existing) continue;
      implicitlyTouchedIds.add(id);
      entities[id] = {
        ...existing,
        mentions: existing.mentions + 1,
        lastSeen: now,
      };
      entryEntityIds.push(id);
    }
  }

  // supersedes — apply AFTER the relations upsert so a supersede in the
  // same patch as a re-assertion of a different relation can't accidentally
  // hide a relation that was just (re-)created in this turn. The extractor
  // is told supersedes references EXISTING RELATIONS only, so collisions
  // here are the model's mistake, not ours.
  for (const id of payload.supersedes ?? []) {
    const target = relations[id];
    if (!target) {
      console.warn("[mergeExtraction] supersedes references unknown id:", id);
      continue;
    }
    if (target.supersededAt) continue;
    relations[id] = { ...target, supersededAt: now };
  }

  // follow-up
  if (payload.followUp?.question) {
    const targetIds = (payload.followUp.targetEntityNames ?? [])
      .map((n) => nameToId[n.toLowerCase()] ?? slugify(n))
      .filter(Boolean);
    const fu: FollowUp = {
      id: `fu-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      question: payload.followUp.question,
      reason: payload.followUp.reason ?? "",
      targetEntityIds: targetIds,
      createdAt: now,
      answered: false,
    };
    followUps.unshift(fu);
    const asked: AskedQuestion = {
      question: payload.followUp.question,
      targetEntityIds: targetIds,
      askedAt: now,
    };
    askedQuestions.unshift(asked);
    if (askedQuestions.length > ASKED_QUESTIONS_CAP) {
      askedQuestions.length = ASKED_QUESTIONS_CAP;
    }
  }

  const entryId = `je-${Date.now()}`;
  const entry: JournalEntry = {
    id: entryId,
    text,
    createdAt: now,
    entityIds: Array.from(new Set(entryEntityIds)),
    relationIds: Array.from(new Set(entryRelationIds)),
  };

  const next: JournalState = {
    entries: [entry, ...prev.entries],
    entities,
    relations,
    followUps,
    askedQuestions,
  };
  return { next, entryId };
}

export function answerFollowUp(state: JournalState, id: string): JournalState {
  return {
    ...state,
    followUps: state.followUps.map((f) => (f.id === id ? { ...f, answered: true } : f)),
  };
}

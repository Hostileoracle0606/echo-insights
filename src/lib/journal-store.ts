import { supabase } from "@/lib/supabase/browser";
import type {
  AskedQuestion,
  Entity,
  ExtractionMode,
  JournalEntry,
  JournalState,
  Relation,
  FollowUp,
  Notebook,
} from "./journal-types";

const MODE_KEY = "lumen.extractionMode.v1";

/**
 * Default mode = "wiki". The product direction is curated/topical
 * extraction; granular is the opt-in for users who want raw capture.
 */
export const DEFAULT_EXTRACTION_MODE: ExtractionMode = "wiki";

// ─── Extraction mode stays in localStorage ───────────────────────
// Per-device preference, not per-account. No reason to round-trip
// through Postgres for a UI toggle.
// ────────────────────────────────────────────────────────────────
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

// ─── Slug helper — unchanged ─────────────────────────────────────
export function slugify(name: string): string {
  return name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 60) || `e-${Math.random().toString(36).slice(2, 8)}`;
}

// ─── Notebook lifecycle ──────────────────────────────────────────

const EMPTY_STATE: JournalState = {
  entries: [],
  entities: {},
  relations: {},
  followUps: [],
  askedQuestions: [],
};

/**
 * Returns the user's most-recent un-ended notebook, or creates a fresh
 * one if none exists. The notebook id is what every read/write in this
 * module scopes to.
 */
export async function ensureActiveNotebook(userId: string): Promise<Notebook> {
  const { data: open } = await supabase
    .from("notebooks")
    .select("*")
    .eq("user_id", userId)
    .is("ended_at", null)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (open) return rowToNotebook(open);

  const now = new Date().toISOString();
  const { data: created, error } = await supabase
    .from("notebooks")
    .insert({
      user_id: userId,
      title: "Untitled Session",
      title_source: "auto",
      started_at: now,
      entity_count: 0,
    })
    .select("*")
    .single();
  if (error || !created) {
    throw new Error(`Failed to create notebook: ${error?.message ?? "unknown"}`);
  }
  return rowToNotebook(created);
}

/**
 * Load the full JournalState for a given notebook. Identical shape
 * to the old localStorage version so consumers don't need changes.
 */
export async function loadState(notebookId?: string): Promise<JournalState> {
  if (!notebookId) return EMPTY_STATE;

  const [entriesRes, entitiesRes, relationsRes, followUpsRes, askedRes] =
    await Promise.all([
      supabase
        .from("journal_entries")
        .select("*")
        .eq("notebook_id", notebookId)
        .order("created_at", { ascending: false }),
      supabase.from("entities").select("*").eq("notebook_id", notebookId),
      supabase.from("relations").select("*").eq("notebook_id", notebookId),
      supabase
        .from("follow_ups")
        .select("*")
        .eq("notebook_id", notebookId)
        .order("created_at", { ascending: false }),
      supabase
        .from("asked_questions")
        .select("*")
        .eq("notebook_id", notebookId)
        .order("asked_at", { ascending: false })
        .limit(ASKED_QUESTIONS_CAP),
    ]);

  if (entriesRes.error || entitiesRes.error || relationsRes.error
      || followUpsRes.error || askedRes.error) {
    console.warn("journal-store loadState partial failure", {
      entries: entriesRes.error, entities: entitiesRes.error,
      relations: relationsRes.error, followUps: followUpsRes.error,
      asked: askedRes.error,
    });
    return EMPTY_STATE;
  }

  return {
    entries: (entriesRes.data ?? []).map(rowToEntry),
    entities: Object.fromEntries(
      (entitiesRes.data ?? []).map((r) => [r.id, rowToEntity(r)]),
    ),
    relations: Object.fromEntries(
      (relationsRes.data ?? []).map((r) => [r.id, rowToRelation(r)]),
    ),
    followUps: (followUpsRes.data ?? []).map(rowToFollowUp),
    askedQuestions: (askedRes.data ?? []).map(rowToAskedQuestion),
  };
}

/**
 * Snapshot-style save: replaces all child rows of the notebook with
 * the supplied state. Used by `mergeExtraction`'s consumer pattern.
 * For high-frequency single-row updates, prefer the targeted helpers
 * (`answerFollowUp`, etc).
 */
export async function saveState(
  notebookId: string,
  userId: string,
  state: JournalState,
): Promise<void> {
  // Replace strategy: delete + insert. RLS guards against cross-tenant
  // damage either way.
  await supabase.from("journal_entries").delete().eq("notebook_id", notebookId);
  await supabase.from("entities").delete().eq("notebook_id", notebookId);
  await supabase.from("relations").delete().eq("notebook_id", notebookId);
  await supabase.from("follow_ups").delete().eq("notebook_id", notebookId);
  await supabase.from("asked_questions").delete().eq("notebook_id", notebookId);

  if (state.entries.length) {
    await supabase.from("journal_entries").insert(
      state.entries.map((e) => ({
        id: e.id, user_id: userId, notebook_id: notebookId,
        text: e.text, created_at: e.createdAt,
      })),
    );
  }
  const entityRows = Object.values(state.entities);
  if (entityRows.length) {
    await supabase.from("entities").insert(
      entityRows.map((e) => ({
        id: e.id, user_id: userId, notebook_id: notebookId,
        name: e.name, type: e.type, description: e.description ?? null,
        metadata: e.metadata, mentions: e.mentions,
        first_seen: e.firstSeen, last_seen: e.lastSeen,
        questions: e.questions ?? null,
      })),
    );
  }
  const relationRows = Object.values(state.relations);
  if (relationRows.length) {
    await supabase.from("relations").insert(
      relationRows.map((r) => ({
        id: r.id, user_id: userId, notebook_id: notebookId,
        source_id: r.source, target_id: r.target, label: r.label,
        metadata: r.metadata, created_at: r.createdAt,
        superseded_at: r.supersededAt ?? null,
      })),
    );
  }
  if (state.followUps.length) {
    await supabase.from("follow_ups").insert(
      state.followUps.map((f) => ({
        id: f.id, user_id: userId, notebook_id: notebookId,
        question: f.question, reason: f.reason,
        target_entity_ids: f.targetEntityIds,
        answered: f.answered, created_at: f.createdAt,
      })),
    );
  }
  const asked = state.askedQuestions ?? [];
  if (asked.length) {
    await supabase.from("asked_questions").insert(
      asked.map((q) => ({
        user_id: userId, notebook_id: notebookId,
        question: q.question, target_entity_ids: q.targetEntityIds,
        asked_at: q.askedAt,
      })),
    );
  }
}

/**
 * Hard-clear all child rows of the notebook. Used by the "Clear journal"
 * action in /app. Does not delete the notebook row itself — only its
 * children — so the user keeps the empty notebook to continue speaking into.
 */
export async function clearState(notebookId: string): Promise<void> {
  await supabase.from("journal_entries").delete().eq("notebook_id", notebookId);
  await supabase.from("entities").delete().eq("notebook_id", notebookId);
  await supabase.from("relations").delete().eq("notebook_id", notebookId);
  await supabase.from("follow_ups").delete().eq("notebook_id", notebookId);
  await supabase.from("asked_questions").delete().eq("notebook_id", notebookId);
}

// ─── mergeExtraction — UNCHANGED LOGIC, but the result is now
//     written via saveState(notebookId, userId, next) by the caller.
//     Keep the function pure: it takes (prev, text, payload) and
//     returns { next, entryId } exactly as before.
// ────────────────────────────────────────────────────────────────

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
  // entities the model did NOT list in entities[] this turn.
  const implicitlyTouchedIds = new Set<string>();
  for (const r of payload.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    for (const id of [src, tgt]) {
      if (!id) continue;
      if (explicitlyTaggedIds.has(id)) continue;
      if (implicitlyTouchedIds.has(id)) continue;
      const existing = entities[id];
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

  // supersedes
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

// ─── Row → domain mappers ────────────────────────────────────────
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToNotebook(r: any): Notebook {
  return {
    id: r.id,
    userId: r.user_id,
    title: r.title,
    titleSource: r.title_source,
    startedAt: r.started_at,
    endedAt: r.ended_at ?? undefined,
    durationSeconds: r.duration_seconds ?? undefined,
    entityCount: r.entity_count,
    summary: r.summary ?? undefined,
    archivedAt: r.archived_at ?? undefined,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToEntry(r: any): JournalEntry {
  return {
    id: r.id, text: r.text, createdAt: r.created_at,
    entityIds: [], relationIds: [],  // recomputed by mergeExtraction
  };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToEntity(r: any): Entity {
  return {
    id: r.id, name: r.name, type: r.type,
    description: r.description ?? undefined,
    metadata: r.metadata ?? {},
    mentions: r.mentions,
    firstSeen: r.first_seen, lastSeen: r.last_seen,
    questions: r.questions ?? undefined,
  };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToRelation(r: any): Relation {
  return {
    id: r.id, source: r.source_id, target: r.target_id,
    label: r.label, metadata: r.metadata ?? {},
    createdAt: r.created_at,
    supersededAt: r.superseded_at ?? undefined,
  };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToFollowUp(r: any): FollowUp {
  return {
    id: r.id, question: r.question, reason: r.reason,
    targetEntityIds: r.target_entity_ids ?? [],
    createdAt: r.created_at, answered: r.answered,
  };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function rowToAskedQuestion(r: any): AskedQuestion {
  return {
    question: r.question,
    targetEntityIds: r.target_entity_ids ?? [],
    askedAt: r.asked_at,
  };
}

import { supabase } from "@/lib/supabase/browser";
import type { EntityChange, NotebookChange, RelationChange } from "./notebook-commit";
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
  return (
    name
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 60) || `e-${Math.random().toString(36).slice(2, 8)}`
  );
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
): { next: JournalState; entryId: string; change: NotebookChange } {
  const now = new Date().toISOString();
  const entities = { ...prev.entities };
  const relations = { ...prev.relations };
  const followUps = [...prev.followUps];
  const askedQuestions = [...(prev.askedQuestions ?? [])];
  const entryEntityIds: string[] = [];
  const entryRelationIds: string[] = [];
  // Every relation id this merge created, re-asserted, OR superseded — the
  // full set commit_notebook needs to upsert. entryRelationIds alone would
  // miss a relation touched only via payload.supersedes.
  const touchedRelationIds = new Set<string>();

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
    touchedRelationIds.add(rid);
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
    touchedRelationIds.add(id);
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
  const uniqueEntryEntityIds = Array.from(new Set(entryEntityIds));
  const uniqueEntryRelationIds = Array.from(new Set(entryRelationIds));
  const entry: JournalEntry = {
    id: entryId,
    text,
    createdAt: now,
    entityIds: uniqueEntryEntityIds,
    relationIds: uniqueEntryRelationIds,
  };

  const next: JournalState = {
    entries: [entry, ...prev.entries],
    entities,
    relations,
    followUps,
    askedQuestions,
  };

  // The domain change commit_notebook needs: full current values for every
  // entity/relation this merge touched (upserts are "changed rows, in full",
  // not field-level diffs — the server doesn't recompute mention counts or
  // question de-duplication, it trusts what mergeExtraction already worked
  // out). followUp/askedQuestion carry content only; the server mints their
  // durable UUIDs.
  const latestFollowUp = followUps[0];
  const latestAsked = askedQuestions[0];
  const change: NotebookChange = {
    kind: "applyTurn",
    entry: { text, entityIds: uniqueEntryEntityIds, relationIds: uniqueEntryRelationIds },
    entities: uniqueEntryEntityIds.map((id): EntityChange => entities[id]),
    relations: Array.from(touchedRelationIds).map((id): RelationChange => relations[id]),
    ...(latestFollowUp && latestFollowUp.createdAt === now
      ? {
          followUp: {
            question: latestFollowUp.question,
            reason: latestFollowUp.reason,
            targetEntityIds: latestFollowUp.targetEntityIds,
          },
        }
      : {}),
    ...(latestAsked && latestAsked.askedAt === now
      ? {
          askedQuestion: {
            question: latestAsked.question,
            targetEntityIds: latestAsked.targetEntityIds,
          },
        }
      : {}),
  };

  return { next, entryId, change };
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

import type { Entity, JournalEntry, JournalState, Relation, FollowUp } from "./journal-types";

const KEY = "lumen.journal.v1";

export function loadState(): JournalState {
  if (typeof window === "undefined") {
    return { entries: [], entities: {}, relations: {}, followUps: [] };
  }
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { entries: [], entities: {}, relations: {}, followUps: [] };
    const parsed = JSON.parse(raw) as JournalState;
    return {
      entries: parsed.entries ?? [],
      entities: parsed.entities ?? {},
      relations: parsed.relations ?? {},
      followUps: parsed.followUps ?? [],
    };
  } catch {
    return { entries: [], entities: {}, relations: {}, followUps: [] };
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
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string | number | boolean>;
  }>;
  followUp?: { question: string; reason: string; targetEntityNames: string[] };
}

export function mergeExtraction(
  prev: JournalState,
  text: string,
  payload: ExtractedPayload,
): { next: JournalState; entryId: string } {
  const now = new Date().toISOString();
  const entities = { ...prev.entities };
  const relations = { ...prev.relations };
  const followUps = [...prev.followUps];
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
        };
    entryEntityIds.push(id);
  }

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
      relations[rid] = {
        ...relations[rid],
        metadata: { ...relations[rid].metadata, ...(r.metadata ?? {}) },
      };
    }
    entryRelationIds.push(rid);
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
  };
  return { next, entryId };
}

export function answerFollowUp(state: JournalState, id: string): JournalState {
  return {
    ...state,
    followUps: state.followUps.map((f) => (f.id === id ? { ...f, answered: true } : f)),
  };
}

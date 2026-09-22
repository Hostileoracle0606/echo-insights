// Vendored from github.com/Hostileoracle0606/graphloop (src/types.ts), 2026-06-17.
// Trimmed to the retrieval subset. Lumen's own Entity/Relation/JournalEntry in
// src/lib/journal-types.ts are structurally identical to Entity/Relation/GraphEntry here.

export type EntityType =
  | "person"
  | "place"
  | "organization"
  | "project"
  | "event"
  | "activity"
  | "concept"
  | "emotion"
  | "other";

export interface Entity {
  id: string;
  name: string;
  type: EntityType;
  description?: string;
  metadata: Record<string, string | number | boolean>;
  mentions: number;
  firstSeen: string;
  lastSeen: string;
  questions?: string[];
}

export interface Relation {
  id: string;
  source: string;
  target: string;
  label: string;
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  supersededAt?: string;
}

export interface GraphEntry {
  id: string;
  text: string;
  createdAt: string;
  entityIds: string[];
  relationIds: string[];
}

export interface GraphState {
  entities: Record<string, Entity>;
  relations: Record<string, Relation>;
  entries: GraphEntry[];
}

export const emptyState = (): GraphState => ({ entities: {}, relations: {}, entries: [] });

export interface RankWeights {
  relevance: number;
  recency: number;
  importance: number;
  confidence: number;
}

export const DEFAULT_RANK_WEIGHTS: RankWeights = {
  relevance: 1.0,
  recency: 0.3,
  importance: 0.4,
  confidence: 0.3,
};

export interface RetrievalOptions {
  hops?: number; // default 2
  maxEntities?: number; // default 24
  maxRelations?: number; // default 48
  tier?: "local" | "global" | "auto"; // default "auto"
  mode?: "lexical" | "hybrid" | "auto"; // default "auto" (hybrid iff embeddingModel)
  weights?: Partial<RankWeights>;
}

export interface CommunitySummary {
  id: number;
  label: string;
  entityIds: string[];
  size: number;
  topEntities: string[];
}

export interface RetrievalResult {
  entities: Entity[];
  relations: Relation[];
  entries: GraphEntry[];
  seeds: string[];
  communities?: CommunitySummary[];
  context: string;
}

// Local structural alias so the Deno edge-function copy needs no `ai` import.
// The web build imports the real EmbeddingModel from "ai", so this export is
// unused there and changes no web behavior.
export type EmbeddingModel = { readonly modelId?: string };

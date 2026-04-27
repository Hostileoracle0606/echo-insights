export type EntityType =
  | "person"
  | "place"
  | "organization"
  | "project"
  | "event"
  | "concept"
  | "emotion"
  | "object"
  | "other";

export interface Entity {
  id: string;          // slug
  name: string;
  type: EntityType;
  description?: string;
  metadata: Record<string, string | number | boolean>;
  mentions: number;
  firstSeen: string;   // ISO
  lastSeen: string;    // ISO
}

export interface Relation {
  id: string;
  source: string;      // entity id
  target: string;      // entity id
  label: string;       // e.g. "works_with", "lives_in", "feels"
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  /**
   * When set, the relation has been soft-superseded — typically because
   * the user contradicted it in conversation and the extractor flagged
   * it via `supersedes`. Hidden from the graph view and the Obsidian
   * export; preserved in storage as an audit trail. Reversible: if the
   * user re-asserts the same source/label/target, the merge step clears
   * the timestamp.
   */
  supersededAt?: string;
}

export interface JournalEntry {
  id: string;
  text: string;
  createdAt: string;
  entityIds: string[];
  relationIds: string[];
}

export interface FollowUp {
  id: string;
  question: string;
  reason: string;        // why the AI asked this
  targetEntityIds: string[];
  createdAt: string;
  answered: boolean;
}

export interface JournalState {
  entries: JournalEntry[];
  entities: Record<string, Entity>;
  relations: Record<string, Relation>;
  followUps: FollowUp[];
}

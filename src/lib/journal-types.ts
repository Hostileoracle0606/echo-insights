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

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
  id: string;          // slug
  name: string;
  type: EntityType;
  description?: string;
  metadata: Record<string, string | number | boolean>;
  mentions: number;
  firstSeen: string;   // ISO
  lastSeen: string;    // ISO
  /**
   * Wiki-mode question backlog: lines of questioning Lumen could pursue
   * to deepen this node. Populated by the wiki extractor; left empty by
   * granular mode. Each entry is roughly a wiki page section heading
   * waiting to be filled. We track which have been asked separately via
   * `askedQuestions` on JournalState — the strings here are the open set.
   */
  questions?: string[];
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

export interface AskedQuestion {
  question: string;
  targetEntityIds: string[];
  askedAt: string; // ISO
}

export interface JournalState {
  entries: JournalEntry[];
  entities: Record<string, Entity>;
  relations: Record<string, Relation>;
  followUps: FollowUp[];
  askedQuestions?: AskedQuestion[];
}

/**
 * Extraction mode controls how the Groq extractor decides what becomes a
 * node:
 *  - "wiki":     each node must support a real line of questioning. Fewer,
 *                deeper nodes; question backlog populated; cleaner export.
 *  - "granular": every named entity becomes a node, even passing mentions.
 *                More noise but higher recall — useful when you'd rather
 *                capture everything and prune later.
 */
export type ExtractionMode = "wiki" | "granular";

export interface Notebook {
  id: string;             // uuid
  userId: string;         // auth.users.id
  title: string;
  titleSource: "ai" | "user" | "auto";
  startedAt: string;      // ISO
  endedAt?: string;       // ISO
  durationSeconds?: number;
  entityCount: number;
  summary?: string;
  archivedAt?: string;    // ISO
  createdAt: string;
  updatedAt: string;
}

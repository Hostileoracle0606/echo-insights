import { supabase } from "@/lib/supabase/browser";
import type {
  AskedQuestion,
  Entity,
  FollowUp,
  JournalEntry,
  JournalState,
  Relation,
} from "./journal-types";

/**
 * The one write seam for a notebook's journal/graph data. PostgreSQL owns
 * ownership, write order, UUID generation, atomicity, and retry safety —
 * this module is a thin adapter over the `commit_notebook` /
 * `get_notebook_snapshot` RPCs (see
 * supabase/migrations/20260821000000_notebook_commit_module.sql).
 *
 * A delta, not another full-notebook snapshot: `requestId` is generated once
 * per logical write and retained across retries so a network hiccup can
 * never turn into a duplicate entry or a double-counted mention.
 */

export type EntityChange = Pick<
  Entity,
  | "id"
  | "name"
  | "type"
  | "description"
  | "metadata"
  | "mentions"
  | "firstSeen"
  | "lastSeen"
  | "questions"
>;

export type RelationChange = Pick<
  Relation,
  "id" | "source" | "target" | "label" | "metadata" | "createdAt" | "supersededAt"
>;

export type NotebookChange =
  | {
      kind: "applyTurn";
      entry: {
        text: string;
        entityIds: string[];
        relationIds: string[];
      };
      entities: EntityChange[];
      relations: RelationChange[];
      followUp?: { question: string; reason: string; targetEntityIds: string[] };
      askedQuestion?: { question: string; targetEntityIds: string[] };
    }
  | { kind: "answerFollowUp"; followUpId: string }
  | { kind: "clearNotebook" };

export type CommitOutcome =
  | {
      status: "committed";
      requestId: string;
      revision: number;
      ids: { entryId?: string; followUpId?: string };
    }
  | { status: "conflict"; currentRevision: number }
  | {
      status: "rejected";
      code: "invalidChange" | "notFound" | "requestIdReused" | "commitFailed";
    };

export type NotebookSnapshot = {
  notebookId: string;
  revision: number;
  state: JournalState;
};

/** One requestId per logical write; keep the SAME id across retries. */
export function newRequestId(): string {
  return crypto.randomUUID();
}

export async function commitNotebook(args: {
  notebookId: string;
  expectedRevision: number;
  requestId: string;
  change: NotebookChange;
}): Promise<CommitOutcome> {
  const { data, error } = await supabase.rpc("commit_notebook", {
    p_notebook_id: args.notebookId,
    p_expected_revision: args.expectedRevision,
    p_request_id: args.requestId,
    p_change: args.change,
  });
  if (error) {
    // A transport/auth failure (not a domain rejection — the RPC always
    // resolves those as data). The caller decides retry policy; an "unknown
    // outcome" here means the write may or may not have landed.
    throw new Error(`commitNotebook RPC failed: ${error.message}`);
  }
  return data as CommitOutcome;
}

export async function getNotebookSnapshot(notebookId: string): Promise<NotebookSnapshot | null> {
  const { data, error } = await supabase.rpc("get_notebook_snapshot", {
    p_notebook_id: notebookId,
  });
  if (error) {
    throw new Error(`getNotebookSnapshot RPC failed: ${error.message}`);
  }
  if (!data) return null; // not found, or not owned by the caller
  const snapshot = data as { notebookId: string; revision: number; state: RawState };
  return {
    notebookId: snapshot.notebookId,
    revision: snapshot.revision,
    state: fromRawState(snapshot.state),
  };
}

// The RPC already returns domain-shaped JSON (camelCase, source/target, no
// raw DB column names) — no per-field row mapping needed. The only gap
// between "what Postgres's jsonb functions produce" and JournalState is
// jsonb_object_agg on an empty set of rows, which returns SQL NULL rather
// than `{}`; the migration already guards every aggregate with `coalesce`,
// but this keeps the client resilient even if that ever drifts.
type RawState = {
  entries: JournalEntry[] | null;
  entities: Record<string, Entity> | null;
  relations: Record<string, Relation> | null;
  followUps: FollowUp[] | null;
  askedQuestions: AskedQuestion[] | null;
};

function fromRawState(raw: RawState): JournalState {
  return {
    entries: raw.entries ?? [],
    entities: raw.entities ?? {},
    relations: raw.relations ?? {},
    followUps: raw.followUps ?? [],
    askedQuestions: raw.askedQuestions ?? [],
  };
}

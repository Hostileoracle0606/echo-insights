/**
 * Web adapter: binds the platform-free turn machine to this app's concrete
 * dependencies — the Gemini extractor, the Supabase Notebook Commit module,
 * semantic retrieval, and a browser-local turn journal.
 *
 * Nothing here makes policy decisions. Ordering, identity checks, idempotency
 * and recovery all live in the reducer and pipeline; this file only supplies
 * the I/O those decisions drive.
 */

import { extractGraph, type ConversationTurn, type ExtractGraphResult } from "@/lib/extract-graph";
import {
  compileExtractionContext,
  DEFAULT_EXTRACTION_TOKEN_BUDGET,
} from "@/lib/extraction-context";
import { retrieveMemory } from "@/lib/journal-memory";
import type { ExtractionMode, FollowUp, JournalState } from "@/lib/journal-types";
import { commitNotebook, getNotebookSnapshot, type NotebookChange } from "@/lib/notebook-commit";

import type { PipelineCommitOutcome, TurnJournalStore, TurnPorts } from "./pipeline";
import type { FinalizedTurn, PreparedCommit } from "./types";

const JOURNAL_KEY = "lumen:turn-journal:v1";

/**
 * Durable turn checkpoints, kept in localStorage.
 *
 * Local storage is the right home for this: the whole point is to survive a
 * reload or crash *before* the server knows about the turn. A record is removed
 * only once the notebook commit is confirmed, so anything still here on startup
 * is unfinished work to resume.
 */
export function createLocalTurnJournal(
  storage: Pick<Storage, "getItem" | "setItem"> | null = safeStorage(),
): TurnJournalStore {
  function readAll(): FinalizedTurn[] {
    if (!storage) return [];
    try {
      const raw = storage.getItem(JOURNAL_KEY);
      if (!raw) return [];
      const parsed: unknown = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as FinalizedTurn[]) : [];
    } catch {
      return [];
    }
  }

  function writeAll(turns: FinalizedTurn[]): void {
    if (!storage) return;
    try {
      storage.setItem(JOURNAL_KEY, JSON.stringify(turns));
    } catch {
      /* quota or private mode — recovery degrades, live behaviour does not */
    }
  }

  return {
    async save(turn) {
      const turns = readAll();
      const index = turns.findIndex((t) => t.turnId === turn.turnId);
      // Preserve insertion order: pending turns must replay in the order they
      // were spoken, not in whatever order they were last checkpointed.
      if (index >= 0) turns[index] = turn;
      else turns.push(turn);
      writeAll(turns);
    },
    async remove(turnId) {
      writeAll(readAll().filter((t) => t.turnId !== turnId));
    },
    async load(notebookId) {
      return readAll()
        .filter((t) => t.notebookId === notebookId && t.stage !== "committed")
        .sort((a, b) => a.finalizedAt.localeCompare(b.finalizedAt));
    },
  };
}

function safeStorage(): Pick<Storage, "getItem" | "setItem"> | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

export interface WebTurnAdapterDeps {
  /** Current local journal state, read fresh at each awaited boundary. */
  getState: () => JournalState;
  /** Canonical, finalized conversation turns for grounding. */
  getConversation: () => ConversationTurn[];
  getExtractionMode: () => ExtractionMode;
  getRevision: () => number;
  setRevision: (revision: number) => void;
  /** Replaces optimistic state with an authoritative server snapshot. */
  replaceState: (state: JournalState) => void;
  /** The open follow-up this turn answers, if any. */
  getAnsweringFollowUp?: () => FollowUp | undefined;
  /**
   * Merges an extraction into local state and returns the change to commit.
   * Called once per commit attempt. Unknown-outcome retries reuse its durable
   * result; a confirmed conflict calls it again after the snapshot reload.
   */
  mergeForCommit: (
    transcript: string,
    payload: ExtractGraphResult,
  ) => { change: NotebookChange; entryId: string; tempFollowUpId?: string };
  /** Reconciles server-assigned ids after a committed write. */
  onCommitted?: (args: {
    turn: FinalizedTurn;
    revision: number;
    entryId: string;
    tempFollowUpId?: string;
    ids: { entryId?: string; followUpId?: string };
  }) => void;
  onError?: (message: string) => void;
  scheduleDeadline?: TurnPorts["scheduleDeadline"];
  tokenBudget?: number;
}

/** Milliseconds to wait for an authoritative transcript after turn completion. */
export const FINALIZATION_DEADLINE_MS = 1500;

export function createWebTurnPorts(deps: WebTurnAdapterDeps): TurnPorts {
  const journal = createLocalTurnJournal();
  const budget = deps.tokenBudget ?? DEFAULT_EXTRACTION_TOKEN_BUDGET;

  return {
    async extract(transcript, key, signal) {
      const state = deps.getState();
      // The finalized transcript is the retrieval query: what the user just
      // said decides which older facts are worth paying prompt tokens for.
      const retrieval = await retrieveMemory(state, transcript, key.notebookId);
      const context = compileExtractionContext({
        transcript,
        state,
        retrieval,
        answeringFollowUp: deps.getAnsweringFollowUp?.(),
        recentTurns: deps.getConversation(),
        budget,
      });
      const result = await extractGraph(
        { text: transcript, context: context.clientContext },
        signal,
        deps.getExtractionMode(),
      );
      // Gemini owns dialogue, so the extractor's follow-up is suppressed here.
      // Entities, relations and supersedes all survive.
      return { ...result, followUp: undefined as unknown as ExtractGraphResult["followUp"] };
    },

    async prepareCommit(turn): Promise<PreparedCommit> {
      if (!turn.extraction) throw new Error("cannot prepare a commit without an extraction");
      // This runs once for an attempt. Unknown-outcome retries reuse the
      // checkpointed result; a confirmed conflict invalidates it so this can
      // rebase once against the freshly loaded snapshot.
      const merged = deps.mergeForCommit(turn.transcript, turn.extraction);
      return {
        expectedRevision: turn.baseRevision ?? deps.getRevision(),
        change: merged.change,
        entryId: merged.entryId,
        tempFollowUpId: merged.tempFollowUpId,
      };
    },

    async commit(turn, prepared): Promise<PipelineCommitOutcome> {
      const outcome = await commitNotebook({
        notebookId: turn.notebookId,
        expectedRevision: prepared.expectedRevision,
        requestId: turn.commitRequestId,
        change: prepared.change as NotebookChange,
      });
      if (outcome.status === "committed") {
        deps.setRevision(outcome.revision);
        deps.onCommitted?.({
          turn,
          revision: outcome.revision,
          entryId: prepared.entryId,
          tempFollowUpId: prepared.tempFollowUpId,
          ids: outcome.ids,
        });
        return { status: "committed", requestId: turn.commitRequestId, revision: outcome.revision };
      }
      if (outcome.status === "conflict") {
        return { status: "conflict", currentRevision: outcome.currentRevision };
      }
      return { status: "rejected", code: outcome.code };
    },

    async reloadSnapshot(notebookId) {
      const snapshot = await getNotebookSnapshot(notebookId);
      if (!snapshot) return null;
      deps.replaceState(snapshot.state);
      deps.setRevision(snapshot.revision);
      return { revision: snapshot.revision };
    },

    journal,

    scheduleDeadline:
      deps.scheduleDeadline ??
      ((_speaker, _turnId, fire) => {
        setTimeout(fire, FINALIZATION_DEADLINE_MS);
      }),

    onError: deps.onError,
  };
}

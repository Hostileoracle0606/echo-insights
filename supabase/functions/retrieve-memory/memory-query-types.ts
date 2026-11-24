import type { MemoryQuote } from "../_shared/retrieve-memory-contract.ts";

export type MemoryRoute = {
  operation: "recall" | "confirm_event" | "calculate" | "conversation";
  timeScope:
    | "current"
    | "previous"
    | "as_of"
    | "compare_versions"
    | "unspecified";
};

export type MemoryPassage = {
  entryId: string;
  notebookId: string;
  text: string;
  spokenAt: string | null;
  createdAt: string;
};

export type MemoryVerdict = {
  status:
    | "supported"
    | "clarification"
    | "insufficient_evidence"
    | "conversation";
  text: string;
  sourceIds: string[];
};

export type MemoryQueryResponse = {
  version: 3;
  context: "";
  entityIds: [];
  quotes: MemoryQuote[];
  verdict: MemoryVerdict;
};

export function memoryQueryResponse(
  verdict: MemoryVerdict = {
    status: "insufficient_evidence",
    text: "I don't have enough in your journal to answer that.",
    sourceIds: [],
  },
  quotes: MemoryQuote[] = [],
): MemoryQueryResponse {
  return { version: 3, context: "", entityIds: [], quotes, verdict };
}

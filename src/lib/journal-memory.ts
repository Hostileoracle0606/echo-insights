import type { JournalState } from "@/lib/journal-types";
import { SearchIndex } from "@/lib/graphloop/search-index";
import { buildCommunities } from "@/lib/graphloop/communities";
import { retrieve } from "@/lib/graphloop/retrieve";
import type { GraphState, RetrievalOptions, RetrievalResult } from "@/lib/graphloop/types";

const EMPTY_RESULT: RetrievalResult = {
  entities: [],
  relations: [],
  entries: [],
  seeds: [],
  context: "",
};

/**
 * Lumen JournalState → GraphLoop GraphState. The two share identical
 * Entity/Relation/Entry shapes, so this is a field pick, not a transform.
 * followUps/askedQuestions are intentionally dropped — retrieval never uses them.
 */
export function toGraphState(state: JournalState): GraphState {
  return { entities: state.entities, relations: state.relations, entries: state.entries };
}

// One Orama index per notebook. Recreated when the active notebook changes so a
// new session never searches a stale graph. Phase 1 scope = active notebook only.
let activeKey: string | null = null;
let index: SearchIndex | null = null;

function indexFor(key: string): SearchIndex {
  if (activeKey !== key || !index) {
    activeKey = key;
    index = new SearchIndex();
  }
  return index;
}

/** Drop the cached index (call on notebook switch / clear / fresh load). */
export function resetMemoryIndex(): void {
  activeKey = null;
  index = null;
}

/**
 * Retrieve memory relevant to `query` from the active notebook's JournalState.
 * Lexical BM25 + k-hop expansion + Louvain community fallback. No LLM calls.
 * Fail-closed: any error returns an empty result so a recall failure never
 * breaks the live turn.
 */
export async function retrieveMemory(
  state: JournalState,
  query: string,
  notebookKey: string,
  opts?: RetrievalOptions,
): Promise<RetrievalResult> {
  try {
    const q = query.trim();
    if (!q) return EMPTY_RESULT;
    const g = toGraphState(state);
    const idx = indexFor(notebookKey);
    await idx.sync(Object.values(g.entities));
    const communities = buildCommunities(g);
    return await retrieve(g, q, { mode: "lexical", ...opts }, { index: idx, communities });
  } catch (err) {
    console.warn("[journal-memory] retrieve failed", err);
    return EMPTY_RESULT;
  }
}

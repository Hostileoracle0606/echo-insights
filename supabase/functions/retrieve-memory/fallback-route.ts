import type { MemoryRoute } from "./memory-query-types.ts";

/**
 * The route when the Decisions router declines (low confidence, a conflict, a
 * timeout or no key): decided by code from the question's wording, so the
 * user is never told the journal couldn't be checked. Conservative: a
 * question with no sign of asking about the past is conversation, so
 * nothing is looked up for "Ask me something interesting."
 */
const RECALL_CUE =
  /\b(my|mine|did i|have i|was i|i said|i told|told you|remember|what did|how much|how many|when (?:is|was|did)|where (?:is|was|did))\b/i;
const CALCULATE =
  /\b(total|sum|altogether|combined|in all|add up|come to|difference|compared? to|versus|vs|more than|less than|how much more|how much less)\b/i;
const CONFIRM = /^\s*(did|have|has|had|was|were)\s+(i|we|she|he|they|it)\b/i;
const CHANGE = /\b(go up|go down|went up|went down|change[ds]?|increase[ds]?|decrease[ds]?|grow|grew|drop(?:ped)?)\b/i;
const AS_OF =
  /\b\d{4}-\d{2}-\d{2}\b|\bin\s+(january|february|march|april|may|june|july|august|september|october|november|december)\b/i;
const PREVIOUS = /\b(before|previous|previously|used to|earlier|originally)\b/i;
const CURRENT = /\b(now|currently|current|these days|at the moment|right now|latest)\b/i;

export function fallbackRoute(question: string): MemoryRoute {
  if (!RECALL_CUE.test(question)) return { operation: "conversation", timeScope: "unspecified" };
  if (CALCULATE.test(question)) return { operation: "calculate", timeScope: "unspecified" };
  if (CONFIRM.test(question) && !CHANGE.test(question)) {
    return { operation: "confirm_event", timeScope: "unspecified" };
  }
  if (CHANGE.test(question)) return { operation: "recall", timeScope: "compare_versions" };
  if (AS_OF.test(question)) return { operation: "recall", timeScope: "as_of" };
  if (PREVIOUS.test(question)) return { operation: "recall", timeScope: "previous" };
  if (CURRENT.test(question)) return { operation: "recall", timeScope: "current" };
  return { operation: "recall", timeScope: "unspecified" };
}

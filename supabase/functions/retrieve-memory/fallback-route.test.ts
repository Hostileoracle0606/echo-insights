import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { fallbackRoute } from "./fallback-route.ts";

// When the Decisions router declines (low confidence, conflict, timeout), the
// question is still routed, by code. Before this, the user heard "I couldn't
// check your journal just now", even for "Ask me something interesting."

const cases: [string, string, string][] = [
  ["Ask me something interesting.", "conversation", "unspecified"],
  ["That's lovely, thanks.", "conversation", "unspecified"],
  ["How much is my rent now?", "recall", "current"],
  ["What was my rent before?", "recall", "previous"],
  ["How much did my savings goal go up?", "recall", "compare_versions"],
  ["Did I raise my savings goal to 10k?", "confirm_event", "unspecified"],
  ["Have I actually cancelled the gym?", "confirm_event", "unspecified"],
  ["What do my rent and groceries come to in total?", "calculate", "unspecified"],
  ["How much more is rent than groceries?", "calculate", "unspecified"],
  ["What was my savings goal on 2026-11-01?", "recall", "as_of"],
  ["What was my rent in October?", "recall", "as_of"],
  ["What did I say about Priya?", "recall", "unspecified"],
  ["Do you remember what I told you about Lisbon?", "recall", "unspecified"],
];

for (const [question, operation, timeScope] of cases) {
  Deno.test(`fallback: ${question}`, () => {
    assertEquals(fallbackRoute(question), { operation, timeScope });
  });
}

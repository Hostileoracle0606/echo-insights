import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { MemoryFact } from "../_shared/memory-fact-contract.ts";
import { answerFromFacts, type FactEntity } from "./fact-answers.ts";
import type { MemoryRoute } from "./memory-query-types.ts";

// EC-06: exact questions are answered from stored facts by code, with no model
// call after the router. These port the resolver's eval cases (evidence.ts,
// MQ-04/MQ-05) onto typed facts: versions, plan versus done, totals,
// differences, as-of dates, units.

let n = 0;
const fact = (
  entityId: string,
  attribute: string,
  value: number | string,
  statedAt: string,
  extra: Partial<MemoryFact> = {},
): MemoryFact => ({
  id: `f${++n}`,
  entityId,
  attribute,
  valueNum: typeof value === "number" ? value : null,
  valueText: typeof value === "string" ? value : null,
  unit: typeof value === "number" ? "USD" : null,
  status: "confirmed",
  eventAt: null,
  statedAt: `${statedAt}T10:00:00+00:00`,
  supersedesFactId: null,
  provenance: "extracted",
  sourceNotebookId: null,
  sourceEntryId: `e-${entityId}-${statedAt}`,
  ...extra,
});

const entities: FactEntity[] = [
  { id: "savings-goal", name: "savings goal" },
  { id: "rent", name: "rent" },
  { id: "groceries", name: "groceries" },
  { id: "gym", name: "gym membership" },
];
const goal = [
  fact("savings-goal", "amount", 5000, "2026-10-03"),
  fact("savings-goal", "amount", 5000, "2026-10-10"),
  fact("savings-goal", "amount", 8000, "2026-11-20"),
];
const route = (operation: MemoryRoute["operation"], timeScope: MemoryRoute["timeScope"]): MemoryRoute => ({
  operation,
  timeScope,
});
const ask = (question: string, r: MemoryRoute, facts: MemoryFact[]) =>
  answerFromFacts(question, r, entities, facts);

Deno.test("current and previous versions, in any input order", () => {
  for (const facts of [goal, [...goal].reverse()]) {
    const now = ask("What's my savings goal now?", route("recall", "current"), facts)!;
    assertEquals(now.status, "supported");
    assertEquals(now.text, "Savings goal amount: 8000 USD (latest stored, said 20 Nov 2026).");
    const before = ask("What was my savings goal before?", route("recall", "previous"), facts)!;
    assertEquals(before.text, "Savings goal amount before that: 5000 USD (said 10 Oct 2026).");
  }
});

Deno.test("the same value said twice is one version", () => {
  const before = ask("What was my previous savings goal?", route("recall", "previous"), goal.slice(0, 2))!;
  assertEquals(before.status, "clarification");
  assertEquals(before.text, "I only have one value stored for that, so there is no earlier one.");
});

Deno.test("the change between versions is computed, not guessed", () => {
  const change = ask("How much did my savings goal go up?", route("calculate", "compare_versions"), goal)!;
  assertEquals(change.text, "Savings goal amount went from 5000 USD to 8000 USD: up 3000 USD.");
});

Deno.test("a plan does not replace the confirmed value, and is not reported as done", () => {
  const facts = [...goal, fact("savings-goal", "amount", 10000, "2026-11-21", { status: "proposed" })];
  assertEquals(ask("What's my savings goal?", route("recall", "current"), facts)!.text,
    "Savings goal amount: 8000 USD (latest stored, said 20 Nov 2026).");
  const did = ask("Did I raise my savings goal to 10k?", route("confirm_event", "unspecified"), facts)!;
  assertEquals(did.status, "clarification");
  assertEquals(did.text,
    "Savings goal amount: 10000 USD was planned (said 21 Nov 2026), but nothing stored says it happened.");
});

Deno.test("a plan later confirmed is reported as done; a cancelled one as called off", () => {
  const plan = fact("gym", "status", "cancelled", "2026-11-01", { status: "proposed" });
  const done = fact("gym", "status", "cancelled", "2026-11-05");
  assertEquals(ask("Did I cancel my gym membership?", route("confirm_event", "unspecified"), [plan, done])!.text,
    "Yes: gym membership status: cancelled (said 5 Nov 2026).");
  const off = fact("gym", "status", "cancelled", "2026-11-06", { status: "cancelled" });
  assertEquals(ask("Did I cancel my gym membership?", route("confirm_event", "unspecified"), [plan, off])!.text,
    "Gym membership status: cancelled was called off (said 6 Nov 2026).");
});

Deno.test("a total adds distinct items once each, in one unit", () => {
  const facts = [
    fact("rent", "amount", 1700, "2026-11-05"),
    fact("groceries", "amount", 400.25, "2026-11-06"),
    fact("groceries", "amount", 400.25, "2026-11-06"),
  ];
  const total = ask("What do rent and groceries come to in total?", route("calculate", "unspecified"), facts)!;
  assertEquals(total.status, "supported");
  assertEquals(total.text, "Rent amount 1700 USD + groceries amount 400.25 USD = 2100.25 USD.");
});

Deno.test("a difference follows the question's order", () => {
  const facts = [fact("rent", "amount", 1700, "2026-11-05"), fact("groceries", "amount", 400, "2026-11-06")];
  assertEquals(ask("How much more is rent than groceries?", route("calculate", "unspecified"), facts)!.text,
    "Rent amount 1700 USD minus groceries amount 400 USD = 1300 USD.");
  assertEquals(ask("Groceries compared to rent?", route("calculate", "unspecified"), facts)!.text,
    "Groceries amount 400 USD minus rent amount 1700 USD = -1300 USD.");
});

Deno.test("different units are never combined", () => {
  const facts = [
    fact("rent", "amount", 1700, "2026-11-05"),
    fact("groceries", "amount", 300, "2026-11-06", { unit: "EUR" }),
  ];
  const total = ask("Rent and groceries in total?", route("calculate", "unspecified"), facts)!;
  assertEquals(total.status, "clarification");
  assertEquals(total.text, "Those values are in different units (USD, EUR), so I can't combine them.");
});

Deno.test("as of a date or a month: the value in effect then", () => {
  assertEquals(ask("What was my savings goal on 2026-11-01?", route("recall", "as_of"), goal)!.text,
    "Savings goal amount on 2026-11-01: 5000 USD (said 10 Oct 2026).");
  assertEquals(ask("What was my savings goal in November 2026?", route("recall", "as_of"), goal)!.text,
    "Savings goal amount in November 2026: 8000 USD (said 20 Nov 2026).");
  assertEquals(ask("What was my savings goal on 2026-09-01?", route("recall", "as_of"), goal)!.status,
    "insufficient_evidence");
  assertEquals(ask("What was my savings goal back then?", route("recall", "as_of"), goal)!.text,
    "Which date or month do you mean?");
});

Deno.test("the attribute the question names is the one answered", () => {
  const facts = [
    fact("rent", "amount", 1700, "2026-11-05"),
    fact("rent", "due_day", "the 1st", "2026-11-05"),
  ];
  assertEquals(ask("When is my rent due?", route("recall", "current"), facts)!.text,
    "Rent due day: the 1st (latest stored, said 5 Nov 2026).");
});

Deno.test("no stored fact means no fact answer: the caller falls back to quotes", () => {
  assertEquals(ask("What's my savings goal?", route("recall", "current"), []), null);
});

Deno.test("the sources are the entries the facts came from", () => {
  const now = ask("What's my savings goal now?", route("recall", "current"), goal)!;
  assertEquals(now.sourceIds, ["e-savings-goal-2026-11-20"]);
});

Deno.test("a question naming a value is checked against that value, not just the latest", () => {
  // Found on staging: extraction missed the plan, and "Did I raise my savings
  // goal to 10k?" was answered "Yes: ... 5000 USD".
  const notThere = ask("Did I raise my savings goal to 10k?", route("confirm_event", "unspecified"), goal)!;
  assertEquals(notThere.status, "clarification");
  assertEquals(notThere.text,
    "Savings goal amount is 8000 USD (said 20 Nov 2026); nothing stored says it was 10000.");
  const there = ask("Did I raise my savings goal to 8k?", route("confirm_event", "unspecified"), goal)!;
  assertEquals(there.text, "Yes: savings goal amount: 8000 USD (said 20 Nov 2026).");
  const planned = ask("Did I raise my savings goal to 10,000 dollars?", route("confirm_event", "unspecified"),
    [...goal, fact("savings-goal", "amount", 10000, "2026-11-21", { status: "proposed" })])!;
  assertEquals(planned.status, "clarification");
  assertEquals(planned.text.startsWith("Savings goal amount: 10000 USD was planned"), true);
});

Deno.test("an amount like 2000 is a value; a date in the question is not", () => {
  const rent = [fact("rent", "amount", 2000, "2026-11-05")];
  assertEquals(ask("Did I set my rent to 2000?", route("confirm_event", "unspecified"), rent)!.text,
    "Yes: rent amount: 2000 USD (said 5 Nov 2026).");
  assertEquals(ask("Did I set my rent to 2000 in November 2026?", route("confirm_event", "unspecified"), rent)!.text,
    "Yes: rent amount: 2000 USD (said 5 Nov 2026).");

  // With a later, different value: 2000 must still be read as the amount asked about.
  const changed = [...rent, fact("rent", "amount", 2500, "2026-11-10")];
  assertEquals(ask("Did I set my rent to 2000?", route("confirm_event", "unspecified"), changed)!.text,
    "Yes: rent amount: 2000 USD (said 5 Nov 2026).");
});

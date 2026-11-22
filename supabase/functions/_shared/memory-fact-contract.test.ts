import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import schema from "../../../contracts/memory-fact-v1.schema.json" with { type: "json" };
import current from "../../../contracts/fixtures/memory-fact-v1.current.json" with { type: "json" };
import empty from "../../../contracts/fixtures/memory-fact-v1.empty.json" with { type: "json" };
import history from "../../../contracts/fixtures/memory-fact-v1.history.json" with { type: "json" };
import {
  FACT_STATUSES,
  isMemoryFact,
  isMemoryFactHistory,
  isMemoryFactResult,
} from "./memory-fact-contract.ts";

// get_memory_fact / get_memory_fact_history (EC-02) answer in this shape; the
// fact tools (EC-06) read it. The shared fixtures keep the database and the
// server code from drifting apart.

Deno.test("the shared fact fixtures satisfy the contract", () => {
  assert(isMemoryFactResult(current));
  assert(isMemoryFactResult(empty));
  assert(isMemoryFactHistory(history));
});

Deno.test("a fact needs a value, a known status and provenance", () => {
  const fact = current.fact;
  assert(isMemoryFact(fact));
  assertEquals(isMemoryFact({ ...fact, valueNum: null, valueText: null }), false);
  assertEquals(isMemoryFact({ ...fact, status: "done" }), false);
  assertEquals(isMemoryFact({ ...fact, provenance: "guessed" }), false);
  assertEquals(isMemoryFact({ ...fact, statedAt: "yesterday" }), false);
  assertEquals(isMemoryFact({ ...fact, valueNum: "8000" }), false);
});

Deno.test("the schema and the validator list the same statuses and fields", () => {
  assertEquals(
    [...schema.$defs.fact.properties.status.enum].sort(),
    [...FACT_STATUSES].sort(),
  );
  assertEquals(
    [...schema.$defs.fact.required].sort(),
    Object.keys(current.fact).sort(),
  );
});

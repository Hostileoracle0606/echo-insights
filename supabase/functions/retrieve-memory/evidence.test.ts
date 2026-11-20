import { createEvidenceResolver } from "./evidence.ts";
import type { MemoryPassage, MemoryRoute } from "./memory-query-types.ts";
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const route = (
  operation: MemoryRoute["operation"],
  timeScope: MemoryRoute["timeScope"],
): MemoryRoute => ({ operation, timeScope });
const p = (entryId: string, text: string, date: string): MemoryPassage => ({
  entryId,
  notebookId: "n",
  text,
  spokenAt: date,
  createdAt: date,
});
const passages = [
  p("a", "My goal was 100.", "2025-01-01"),
  p("b", "My goal is now 150.", "2025-02-01"),
];
const fact = (sourceId: string, span: string, value: number, date: string) => ({
  sourceId,
  span,
  value,
  unit: "goal",
  category: "goal",
  date,
  status: "confirmed",
  approximate: false,
});
const facts = [
  fact("a", passages[0].text, 100, "2025-01-01"),
  fact("b", passages[1].text, 150, "2025-02-01"),
];
function resolver(result: unknown) {
  return createEvidenceResolver({
    getApiKey: () => "test",
    fetch: async () =>
      new Response(
        JSON.stringify({
          candidates: [{
            content: { parts: [{ text: JSON.stringify(result) }] },
          }],
        }),
        { status: 200 },
      ),
  });
}
Deno.test("versioned facts and difference are stable across passage order", async () => {
  const run = resolver({ facts, complete: true });
  for (const input of [passages, [...passages].reverse()]) {
    assertEquals(
      (await run(
        "What was my previous goal?",
        route("recall", "previous"),
        input,
        new AbortController().signal,
      )).text,
      "My goal was 100.",
    );
    assertEquals(
      (await run(
        "What is my current goal?",
        route("recall", "current"),
        input,
        new AbortController().signal,
      )).text,
      "My goal is now 150.",
    );
    assertEquals(
      (await run(
        "How much did my goal increase?",
        route("calculate", "compare_versions"),
        input,
        new AbortController().signal,
      )).text,
      "The increase was 50 goal.",
    );
  }
});
Deno.test("rejects forged source text and source IDs", async () => {
  const run = resolver({
    facts: [fact("a", "My goal was 999.", 999, "2025-01-01")],
    complete: true,
  });
  assertEquals(
    (await run(
      "What was my goal?",
      route("recall", "previous"),
      passages,
      new AbortController().signal,
    )).status,
    "insufficient_evidence",
  );
});
Deno.test("proposed coffee change does not replace confirmed cut", async () => {
  const ps = [
    p("a", "I cut my coffee limit to 1 cup.", "2025-01-01"),
    p("b", "I propose going back to 2 cups.", "2025-02-01"),
    p("c", "I confirmed my coffee limit is 2 cups.", "2025-03-01"),
  ];
  const fs = [fact("a", ps[0].text, 1, "2025-01-01"), {
    ...fact("b", ps[1].text, 2, "2025-02-01"),
    status: "proposed",
  }, fact("c", ps[2].text, 2, "2025-03-01")];
  assertEquals(
    (await resolver({ facts: fs.slice(0, 2), complete: true })(
      "What is my current coffee limit?",
      route("recall", "current"),
      ps,
      new AbortController().signal,
    )).text,
    ps[0].text,
  );
  assertEquals(
    (await resolver({ facts: fs, complete: true })(
      "What is my current coffee limit?",
      route("recall", "current"),
      ps,
      new AbortController().signal,
    )).text,
    ps[2].text,
  );
});
Deno.test("event confirmation recognizes a proposal and a later completed change with numbers written as words", async () => {
  const ps = [
    p(
      "a",
      "I was thinking about increasing my coffee limit to two cups.",
      "2025-01-01",
    ),
    p("b", "I raised my coffee limit to two cups today.", "2025-01-02"),
  ];
  const fs = ps.map((passage) =>
    fact(passage.entryId, passage.text, 2, passage.createdAt)
  );
  const question = "Did I actually raise my coffee limit?";
  const event = route("confirm_event", "unspecified");
  const signal = new AbortController().signal;
  assertEquals(
    (await resolver({ facts: fs.slice(0, 1), complete: true })(
      question,
      event,
      ps,
      signal,
    )).status,
    "clarification",
  );
  assertEquals(
    await resolver({ facts: fs, complete: true })(question, event, ps, signal),
    { status: "supported", text: ps[1].text, sourceIds: ["b"] },
  );
});

Deno.test("wrong role and wrong second operand do not support an answer", async () => {
  const ps = [
    p("a", "I bought Mom a candle.", "2025-01-01"),
    p("b", "Headphones cost 100 dollars.", "2025-01-02"),
    p("c", "Phone case cost 20 dollars.", "2025-01-03"),
  ];
  assertEquals(
    (await resolver({
      facts: [fact("a", ps[0].text, null as unknown as number, "2025-01-01")],
      complete: true,
    })(
      "What did Dad give me?",
      route("recall", "unspecified"),
      ps,
      new AbortController().signal,
    )).status,
    "insufficient_evidence",
  );
  const fs = [{
    ...fact("b", ps[1].text, 100, "2025-01-02"),
    category: "headphones",
    unit: "dollars",
  }, {
    ...fact("c", ps[2].text, 20, "2025-01-03"),
    category: "phone case",
    unit: "dollars",
  }];
  assertEquals(
    (await resolver({ facts: fs, complete: true })(
      "What did headphones and an iPad cost?",
      route("calculate", "unspecified"),
      ps,
      new AbortController().signal,
    )).status,
    "clarification",
  );
});
Deno.test("adds four distinct supported categories and deduplicates repeated references", async () => {
  const ps = [12, 57, 25, 5].map((n, i) =>
    p(
      String(i),
      `Category ${String.fromCharCode(65 + i)} has ${n} items.`,
      `2025-01-0${i + 1}`,
    )
  );
  const fs = ps.map((item, i) => ({
    ...fact(item.entryId, item.text, [12, 57, 25, 5][i], item.createdAt),
    unit: "items",
    category: `category ${String.fromCharCode(65 + i)}`,
  }));
  const verdict = await resolver({ facts: [...fs, fs[0]], complete: true })(
    "How many rare items in these four categories?",
    route("calculate", "unspecified"),
    ps,
    new AbortController().signal,
  );
  assertEquals(verdict.text, "The total is 99 items.");
});
Deno.test("compares named operands in question order without inventing exact amounts", async () => {
  const ps = [
    p("a", "Accommodations in Hawaii cost over $300 per night.", "2025-01-01"),
    p("b", "Accommodations in Tokyo cost around $30 per night.", "2025-01-02"),
  ];
  const fs = [{
    ...fact("a", ps[0].text, 300, "2025-01-01"),
    category: "Hawaii",
    unit: "USD",
  }, {
    ...fact("b", ps[1].text, 30, "2025-01-02"),
    category: "Tokyo",
    unit: "USD",
    approximate: true,
  }];
  const run = resolver({ facts: fs, complete: true });
  const a = await run(
    "How much more did I spend on accommodations per night in Hawaii compared to Tokyo?",
    route("calculate", "unspecified"),
    ps,
    new AbortController().signal,
  );
  assertEquals(a.status, "supported");
  assertEquals(
    a.text,
    "Using the stated figures, Hawaii minus Tokyo is 270 USD. The source amounts are qualified: Accommodations in Hawaii cost over $300 per night. Accommodations in Tokyo cost around $30 per night.",
  );
  const b = await run(
    "How much more did I spend in Tokyo compared to Hawaii?",
    route("calculate", "unspecified"),
    ps,
    new AbortController().signal,
  );
  assertEquals(
    b.text,
    "Using the stated figures, Tokyo minus Hawaii is -270 USD. The source amounts are qualified: Accommodations in Tokyo cost around $30 per night. Accommodations in Hawaii cost over $300 per night.",
  );
  const mixed = resolver({
    facts: [fs[0], { ...fs[1], unit: "CAD" }],
    complete: true,
  });
  assertEquals(
    (await mixed(
      "How much more in Hawaii compared to Tokyo?",
      route("calculate", "unspecified"),
      ps,
      new AbortController().signal,
    )).status,
    "clarification",
  );
  assertEquals(
    (await run(
      "What is the difference?",
      route("calculate", "unspecified"),
      ps,
      new AbortController().signal,
    )).status,
    "clarification",
  );
});
Deno.test("as of date selects latest established earlier fact and rejects missing or invalid dates", async () => {
  const run = resolver({ facts, complete: true });
  assertEquals(
    (await run(
      "What was my goal as of 2025-01-15?",
      route("recall", "as_of"),
      passages,
      new AbortController().signal,
    )).text,
    passages[0].text,
  );
  assertEquals(
    (await run(
      "What was my goal on 2024-01-01?",
      route("recall", "as_of"),
      passages,
      new AbortController().signal,
    )).status,
    "insufficient_evidence",
  );
  assertEquals(
    (await run(
      "What was my goal then?",
      route("recall", "as_of"),
      passages,
      new AbortController().signal,
    )).status,
    "clarification",
  );
  assertEquals(
    (await run(
      "What was my goal on 2025-02-30?",
      route("recall", "as_of"),
      passages,
      new AbortController().signal,
    )).status,
    "clarification",
  );
});
Deno.test("open ended subtotal is qualified and decimal arithmetic is clean", async () => {
  const ps = [
    p("a", "Item A cost 0.1 USD.", "2025-01-01"),
    p("b", "Item B cost 0.2 USD.", "2025-01-02"),
  ];
  const fs = ps.map((x, i) => ({
    ...fact(x.entryId, x.text, [0.1, 0.2][i], x.createdAt),
    category: `item ${i}`,
    unit: "USD",
  }));
  const result = await resolver({ facts: fs, complete: true })(
    "How much did I spend in total across all entries?",
    route("calculate", "unspecified"),
    ps,
    new AbortController().signal,
  );
  assertEquals(
    result.text,
    "The subtotal from the available entries is 0.3 USD.",
  );
});
Deno.test("explicit currency labels override a generic provider unit", async () => {
  const ps = [
    p("a", "Hawaii cost CAD $300.", "2025-01-01"),
    p("b", "Tokyo cost USD $30.", "2025-01-02"),
  ];
  const fs = ps.map((x, i) => ({
    ...fact(x.entryId, x.text, [300, 30][i], x.createdAt),
    category: ["Hawaii", "Tokyo"][i],
    unit: "dollars",
  }));
  const result = await resolver({ facts: fs, complete: true })(
    "How much more in Hawaii compared to Tokyo?",
    route("calculate", "unspecified"),
    ps,
    new AbortController().signal,
  );
  assertEquals(result.status, "clarification");
});
Deno.test("consecutive mentions of the same value are one version", async () => {
  const ps = [
    p("a", "My goal was 100.", "2025-01-01"),
    p("b", "My goal became 150.", "2025-02-01"),
    p("c", "My goal is still 150.", "2025-03-01"),
  ];
  const fs = ps.map((x, i) =>
    fact(x.entryId, x.text, [100, 150, 150][i], x.createdAt)
  );
  const run = resolver({ facts: fs, complete: true });
  assertEquals(
    (await run(
      "What was my previous goal?",
      route("recall", "previous"),
      ps,
      new AbortController().signal,
    )).text,
    ps[0].text,
  );
  assertEquals(
    (await run(
      "What is my current goal?",
      route("recall", "current"),
      ps,
      new AbortController().signal,
    )).text,
    ps[2].text,
  );
  assertEquals(
    (await run(
      "How much did my goal increase?",
      route("calculate", "compare_versions"),
      ps,
      new AbortController().signal,
    )).text,
    "The increase was 50 goal.",
  );
});
Deno.test("duplicate operands require distinct named scope, even across excerpts", async () => {
  const ps = [
    p("a", "Gift for Alice cost 100 USD.", "2025-01-01"),
    p("b", "Gift for Bob cost 100 USD.", "2025-01-02"),
  ];
  const fs = ps.map((x, i) => ({
    ...fact(x.entryId, x.text, 100, x.createdAt),
    unit: "USD",
    category: ["Alice", "Bob"][i],
  }));
  const run = resolver({ facts: fs, complete: true });
  assertEquals(
    (await run(
      "What is the total for Alice and Bob?",
      route("calculate", "unspecified"),
      ps,
      new AbortController().signal,
    )).text,
    "The total is 200 USD.",
  );
  assertEquals(
    (await run(
      "What is the total for the gifts?",
      route("calculate", "unspecified"),
      ps,
      new AbortController().signal,
    )).status,
    "clarification",
  );
});
Deno.test("month lookup stays in requested month and resolves year only when unique", async () => {
  const ps = [
    p("a", "My goal was 100.", "2026-01-20"),
    p("b", "My goal was 120.", "2026-02-05"),
    p("c", "My goal was 150.", "2026-02-20"),
    p("d", "My goal was 170.", "2027-02-10"),
  ];
  const fs = ps.map((x, i) =>
    fact(x.entryId, x.text, [100, 120, 150, 170][i], x.createdAt)
  );
  const run = resolver({ facts: fs, complete: true });
  assertEquals(
    (await run(
      "What was my goal in February 2026?",
      route("recall", "as_of"),
      ps,
      new AbortController().signal,
    )).text,
    ps[2].text,
  );
  assertEquals(
    (await run(
      "What was my goal in February?",
      route("recall", "as_of"),
      ps,
      new AbortController().signal,
    )).status,
    "clarification",
  );
  const unique = resolver({ facts: fs.slice(0, 3), complete: true });
  assertEquals(
    (await unique(
      "What was my goal in February?",
      route("recall", "as_of"),
      ps,
      new AbortController().signal,
    )).text,
    ps[2].text,
  );
  assertEquals(
    (await unique(
      "What was my goal in March 2026?",
      route("recall", "as_of"),
      ps,
      new AbortController().signal,
    )).status,
    "insufficient_evidence",
  );
});

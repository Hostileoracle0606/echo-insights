import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

import emptyFixture from "../../../contracts/fixtures/retrieve-memory-v1.empty.json" with {
  type: "json",
};
import schema from "../../../contracts/retrieve-memory-v1.schema.json" with {
  type: "json",
};
import successFixture from "../../../contracts/fixtures/retrieve-memory-v1.success.json" with {
  type: "json",
};
import {
  isRetrieveMemoryResponseV1,
  retrieveMemoryResponseV1,
} from "./retrieve-memory-contract.ts";
import v2EmptyFixture from "../../../contracts/fixtures/retrieve-memory-v2.empty.json" with {
  type: "json",
};
import v2NoQuotesFixture from "../../../contracts/fixtures/retrieve-memory-v2.no-quotes.json" with {
  type: "json",
};
import v2Schema from "../../../contracts/retrieve-memory-v2.schema.json" with {
  type: "json",
};
import v2SuccessFixture from "../../../contracts/fixtures/retrieve-memory-v2.success.json" with {
  type: "json",
};
import {
  isRetrieveMemoryResponseV2,
  MAX_QUOTE_CHARS,
  MAX_QUOTES,
  type MemoryQuote,
  retrieveMemoryResponseV2,
} from "./retrieve-memory-contract.ts";

Deno.test("shared retrieve-memory v1 fixtures satisfy the server contract", () => {
  assert(isRetrieveMemoryResponseV1(successFixture));
  assert(isRetrieveMemoryResponseV1(emptyFixture));
});

Deno.test("runtime validation stays aligned with the published v1 schema", () => {
  assertEquals(schema.required, ["version", "context", "entityIds"]);
  assertEquals(schema.properties.version.const, 1);
});

Deno.test("retrieve-memory v1 response includes the required version and entity ids", () => {
  assertEquals(retrieveMemoryResponseV1("focused context", ["maya", "atlas"]), {
    version: 1,
    context: "focused context",
    entityIds: ["maya", "atlas"],
  });
});

Deno.test("retrieve-memory v1 rejects missing or malformed required fields", () => {
  assert(!isRetrieveMemoryResponseV1({ context: "legacy", entityIds: [] }));
  assert(
    !isRetrieveMemoryResponseV1({ version: 1, context: "bad", entityIds: [4] }),
  );
  assert(
    !isRetrieveMemoryResponseV1({
      version: 2,
      context: "future",
      entityIds: [],
    }),
  );
});

// ── v2: user scope with quotes ───────────────────────────────

const quote = (over: Partial<MemoryQuote> = {}): MemoryQuote => ({
  entryId: "entry-1",
  notebookId: "nb-1",
  turnId: null,
  spokenAt: null,
  createdAt: "2026-10-16T17:42:13.000Z",
  notebookTitle: "Friday wrap-up",
  text: "the CI fix is next",
  ...over,
});

Deno.test("shared retrieve-memory v2 fixtures satisfy the server contract", () => {
  assert(isRetrieveMemoryResponseV2(v2SuccessFixture));
  assert(isRetrieveMemoryResponseV2(v2EmptyFixture));
  assert(isRetrieveMemoryResponseV2(v2NoQuotesFixture));
});

Deno.test("v1 and v2 guards never accept each other's fixtures", () => {
  assert(!isRetrieveMemoryResponseV1(v2SuccessFixture));
  assert(!isRetrieveMemoryResponseV2(successFixture));
});

Deno.test("runtime validation stays aligned with the published v2 schema", () => {
  assertEquals(v2Schema.required, ["version", "context", "entityIds", "quotes"]);
  assertEquals(v2Schema.properties.version.const, 2);
  assertEquals(v2Schema.properties.quotes.maxItems, MAX_QUOTES);
  assertEquals(v2Schema.properties.quotes.items.properties.text.maxLength, MAX_QUOTE_CHARS);
  assertEquals(v2Schema.properties.quotes.items.required, [
    "entryId",
    "notebookId",
    "turnId",
    "spokenAt",
    "createdAt",
    "notebookTitle",
    "text",
  ]);
});

Deno.test("retrieve-memory v2 response carries quotes alongside context", () => {
  assertEquals(retrieveMemoryResponseV2("ctx", ["priya"], [quote()]), {
    version: 2,
    context: "ctx",
    entityIds: ["priya"],
    quotes: [quote()],
  });
});

Deno.test("retrieve-memory v2 rejects malformed, oversized or extra quotes", () => {
  const base = { version: 2, context: "c", entityIds: [] };
  assert(!isRetrieveMemoryResponseV2({ ...base }));
  assert(!isRetrieveMemoryResponseV2({ ...base, quotes: [{ ...quote(), entryId: 4 }] }));
  assert(!isRetrieveMemoryResponseV2({ ...base, quotes: [{ ...quote(), turnId: undefined }] }));
  assert(
    !isRetrieveMemoryResponseV2({ ...base, quotes: [quote({ text: "x".repeat(281) })] }),
  );
  assert(
    !isRetrieveMemoryResponseV2({ ...base, quotes: [quote(), quote(), quote(), quote()] }),
  );
  assert(!isRetrieveMemoryResponseV2({ ...base, version: 1, quotes: [] }));
});

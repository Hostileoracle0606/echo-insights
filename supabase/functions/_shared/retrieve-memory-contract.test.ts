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

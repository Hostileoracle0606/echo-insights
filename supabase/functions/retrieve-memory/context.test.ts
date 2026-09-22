import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildContext } from "./context.ts";
import type { RetrievalResult } from "../_shared/graphloop/types.ts";

Deno.test("buildContext emits entities + relations, never a Sources section", () => {
  const result: RetrievalResult = {
    entities: [
      { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 3, firstSeen: "2026-01-01T00:00:00Z", lastSeen: "2026-01-02T00:00:00Z", description: "a friend" },
      { id: "atlas", name: "Atlas", type: "project", metadata: {}, mentions: 2, firstSeen: "2026-01-01T00:00:00Z", lastSeen: "2026-01-02T00:00:00Z" },
    ],
    relations: [
      { id: "r1", source: "maya", target: "atlas", label: "works_on", metadata: {}, createdAt: "2026-01-02T00:00:00Z" },
    ],
    entries: [
      { id: "e1", text: "SENTINEL_SECRET maya is on atlas", createdAt: "2026-01-02T00:00:00Z", entityIds: ["maya", "atlas"], relationIds: ["r1"] },
    ],
    seeds: ["maya"],
    context: "ignored — packer output is not trusted",
  };
  const ctx = buildContext(result);
  assert(ctx.includes("## Entities"));
  assert(ctx.includes("Maya (person)"));
  assert(ctx.includes("Maya --works_on--> Atlas"));
  assert(!ctx.includes("## Sources"), "must not include a Sources section");
  assert(!ctx.includes("SENTINEL_SECRET"), "must not include verbatim entry text");
});

Deno.test("buildContext falls back to the (source-free) global context when no entities", () => {
  const result: RetrievalResult = {
    entities: [], relations: [], entries: [], seeds: [],
    communities: [{ id: 0, label: "area", entityIds: ["a"], size: 1, topEntities: ["A"] }],
    context: "## Relevant areas of memory\n- area (1 entities): A",
  };
  const ctx = buildContext(result);
  assertEquals(ctx, "## Relevant areas of memory\n- area (1 entities): A");
});

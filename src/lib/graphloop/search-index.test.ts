import { describe, expect, test } from "vitest";
import type { Entity } from "./types";
import { SearchIndex } from "./search-index";

const T = "2026-06-12T00:00:00.000Z";
const ent = (id: string, name: string, description?: string): Entity => ({
  id,
  name,
  type: "concept",
  description,
  metadata: {},
  mentions: 1,
  firstSeen: T,
  lastSeen: T,
});

describe("SearchIndex (lexical)", () => {
  test("BM25 finds an entity by name token", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("project-atlas", "Project Atlas"), ent("maya", "Maya")]);
    const hits = await idx.search("atlas", undefined, 5);
    expect(hits[0]?.id).toBe("project-atlas");
  });

  test("incremental sync only re-indexes changed entities", async () => {
    const idx = new SearchIndex();
    const first = await idx.sync([ent("maya", "Maya")]);
    const again = await idx.sync([ent("maya", "Maya")]);
    expect(first.indexed).toBe(1);
    expect(again.indexed).toBe(0); // unchanged → skipped
  });

  test("returns empty for a no-match query", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("maya", "Maya")]);
    expect(await idx.search("nonexistentxyz", undefined, 5)).toEqual([]);
  });

  test("deletion: removed entity no longer appears in search", async () => {
    const idx = new SearchIndex();
    await idx.sync([ent("project-atlas", "Project Atlas"), ent("maya", "Maya")]);
    await idx.sync([ent("maya", "Maya")]); // Atlas dropped from the set
    const hits = await idx.search("atlas", undefined, 5);
    expect(hits.map((h) => h.id)).not.toContain("project-atlas");
  });

  test("content change re-indexes: new description is findable", async () => {
    const idx = new SearchIndex();
    const first = await idx.sync([ent("maya", "Maya", "original bio")]);
    expect(first.indexed).toBe(1);
    const second = await idx.sync([ent("maya", "Maya", "galactic engineer")]);
    expect(second.indexed).toBe(1);
    const hits = await idx.search("galactic", undefined, 5);
    expect(hits.map((h) => h.id)).toContain("maya");
  });
});

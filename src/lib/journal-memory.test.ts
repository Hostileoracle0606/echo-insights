import { beforeEach, describe, expect, test } from "vitest";
import type { JournalState } from "./journal-types";
import { resetMemoryIndex, retrieveMemory, toGraphState } from "./journal-memory";

const T = "2026-06-17T00:00:00.000Z";

const fixture = (): JournalState => ({
  followUps: [],
  askedQuestions: [],
  entities: {
    maya: {
      id: "maya",
      name: "Maya",
      type: "person",
      metadata: {},
      mentions: 1,
      firstSeen: T,
      lastSeen: T,
    },
    "project-atlas": {
      id: "project-atlas",
      name: "Project Atlas",
      type: "project",
      metadata: {},
      mentions: 1,
      firstSeen: T,
      lastSeen: T,
    },
    coffee: {
      id: "coffee",
      name: "coffee",
      type: "concept",
      metadata: {},
      mentions: 1,
      firstSeen: T,
      lastSeen: T,
    },
  },
  relations: {
    "maya__leads__project-atlas": {
      id: "maya__leads__project-atlas",
      source: "maya",
      target: "project-atlas",
      label: "leads",
      metadata: {},
      createdAt: T,
    },
  },
  entries: [
    {
      id: "e1",
      text: "Maya leads Project Atlas",
      createdAt: T,
      entityIds: ["maya", "project-atlas"],
      relationIds: ["maya__leads__project-atlas"],
    },
    { id: "e2", text: "I like coffee", createdAt: T, entityIds: ["coffee"], relationIds: [] },
  ],
});

beforeEach(() => resetMemoryIndex());

describe("journal-memory", () => {
  test("toGraphState picks the three graph fields", () => {
    const g = toGraphState(fixture());
    expect(Object.keys(g)).toEqual(["entities", "relations", "entries"]);
    expect(g.entities.maya?.name).toBe("Maya");
  });

  test("retrieveMemory returns grounded context for a known entity", async () => {
    const r = await retrieveMemory(fixture(), "atlas", "nb-1");
    expect(r.entities.map((e) => e.name)).toContain("Project Atlas");
    expect(r.context).toContain("## Sources");
    expect(r.context).toContain("Maya leads Project Atlas");
  });

  test("empty query returns an empty result", async () => {
    const r = await retrieveMemory(fixture(), "   ", "nb-1");
    expect(r.entities).toEqual([]);
    expect(r.context).toBe("");
  });

  test("no-match query returns a community fallback or honest empty (never the whole graph)", async () => {
    const r = await retrieveMemory(fixture(), "zzzznotpresent", "nb-1");
    expect(r.entities).toEqual([]); // never dumps unrelated nodes
  });
});

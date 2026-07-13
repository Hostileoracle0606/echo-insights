import { describe, expect, test } from "vitest";
import { journalEntryToRow, rowToEntry } from "./journal-rows";
import type { JournalEntry } from "./journal-types";

describe("journal-rows provenance", () => {
  test("round-trips entityIds and relationIds through the row shape", () => {
    const entry: JournalEntry = {
      id: "je-1",
      text: "Maya leads Atlas",
      createdAt: "2026-06-17T00:00:00.000Z",
      entityIds: ["maya", "atlas"],
      relationIds: ["maya__leads__atlas"],
    };
    const row = journalEntryToRow(entry, "u1", "nb1");
    expect(row.entity_ids).toEqual(["maya", "atlas"]);
    expect(row.relation_ids).toEqual(["maya__leads__atlas"]);

    const back = rowToEntry(row);
    expect(back.entityIds).toEqual(["maya", "atlas"]);
    expect(back.relationIds).toEqual(["maya__leads__atlas"]);
  });

  test("rowToEntry defaults missing arrays to empty (old rows)", () => {
    const back = rowToEntry({ id: "je-2", text: "x", created_at: "t" });
    expect(back.entityIds).toEqual([]);
    expect(back.relationIds).toEqual([]);
  });
});

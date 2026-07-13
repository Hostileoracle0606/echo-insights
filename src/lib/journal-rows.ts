import type { JournalEntry } from "./journal-types";

/**
 * Pure mappers between a `journal_entries` Supabase row and a JournalEntry.
 * Extracted from journal-store so the entityIds/relationIds provenance
 * round-trip is testable without importing the Supabase browser client.
 */
export function journalEntryToRow(entry: JournalEntry, userId: string, notebookId: string) {
  return {
    id: entry.id,
    user_id: userId,
    notebook_id: notebookId,
    text: entry.text,
    created_at: entry.createdAt,
    entity_ids: entry.entityIds,
    relation_ids: entry.relationIds,
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function rowToEntry(r: any): JournalEntry {
  return {
    id: r.id,
    text: r.text,
    createdAt: r.created_at,
    entityIds: r.entity_ids ?? [],
    relationIds: r.relation_ids ?? [],
  };
}

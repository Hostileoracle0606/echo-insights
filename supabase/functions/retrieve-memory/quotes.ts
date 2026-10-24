import { MAX_QUOTE_CHARS, MAX_QUOTES, type MemoryQuote } from "../_shared/retrieve-memory-contract.ts";
import type { DbClient } from "./handler.ts";

/** How many of the top-ranked entities we look up mentions for. */
export const QUOTE_ENTITY_COUNT = 3;
/** Mentions fetched per entity (get_entity_mentions, newest first). */
export const MENTIONS_PER_ENTITY = 5;

/** One element of get_entity_mentions(...).mentions (LM-06, LM-01). */
type Mention = {
  entryId: string;
  notebookId: string;
  notebookTitle: string;
  createdAt: string;
  excerpt: string;
  turnId: string | null;
  spokenAt: string | null;
};

const isNullableString = (value: unknown) => value === null || value === undefined || typeof value === "string";

function asMention(value: unknown): Mention | null {
  if (!value || typeof value !== "object") return null;
  const m = value as Record<string, unknown>;
  if (
    typeof m.entryId !== "string" || typeof m.notebookId !== "string" ||
    typeof m.notebookTitle !== "string" || typeof m.createdAt !== "string" ||
    typeof m.excerpt !== "string" || !isNullableString(m.turnId) || !isNullableString(m.spokenAt)
  ) {
    return null;
  }
  return {
    entryId: m.entryId,
    notebookId: m.notebookId,
    notebookTitle: m.notebookTitle,
    createdAt: m.createdAt,
    excerpt: m.excerpt,
    turnId: (m.turnId as string | null | undefined) ?? null,
    spokenAt: (m.spokenAt as string | null | undefined) ?? null,
  };
}

/**
 * Trim to at most [max] UTF-16 units without splitting a surrogate pair.
 * Postgres left(text, 280) counts characters, so an excerpt with emoji can
 * still be longer than the contract's 280 in JavaScript's units.
 */
export function clip(text: string, max = MAX_QUOTE_CHARS): string {
  const t = text.trim();
  if (t.length <= max) return t;
  const code = t.charCodeAt(max - 1);
  const end = code >= 0xd800 && code <= 0xdbff ? max - 1 : max;
  return t.slice(0, end).trimEnd();
}

/**
 * Pure selection: mentions from OTHER notebooks only (the open conversation
 * is already in the model's context), one quote per journal entry, newest
 * first, at most MAX_QUOTES.
 */
export function selectQuotes(mentionLists: unknown[][], currentNotebookId: string): MemoryQuote[] {
  const byEntry = new Map<string, MemoryQuote>();
  for (const list of mentionLists) {
    for (const raw of list) {
      const m = asMention(raw);
      if (!m || m.notebookId === currentNotebookId || byEntry.has(m.entryId)) continue;
      const text = clip(m.excerpt);
      if (!text) continue;
      byEntry.set(m.entryId, {
        entryId: m.entryId,
        notebookId: m.notebookId,
        turnId: m.turnId,
        spokenAt: m.spokenAt,
        createdAt: m.createdAt,
        notebookTitle: m.notebookTitle,
        text,
      });
    }
  }
  return [...byEntry.values()]
    .sort((a, b) =>
      Date.parse(b.createdAt) - Date.parse(a.createdAt) || (a.entryId < b.entryId ? 1 : -1)
    )
    .slice(0, MAX_QUOTES);
}

/**
 * Mentions for the top-ranked entities, read AS THE USER (RLS + auth.uid()
 * in get_entity_mentions keep it to their own entries). Any failure means no
 * quotes; it never fails the request.
 */
export async function loadQuotes(
  userClient: DbClient,
  rankedEntityIds: string[],
  currentNotebookId: string,
): Promise<MemoryQuote[]> {
  const top = rankedEntityIds.slice(0, QUOTE_ENTITY_COUNT);
  if (top.length === 0) return [];
  try {
    const responses = await Promise.all(top.map((id) =>
      userClient.rpc("get_entity_mentions", { p_entity_id: id, p_limit: MENTIONS_PER_ENTITY })
    ));
    const lists: unknown[][] = [];
    for (const { data, error } of responses) {
      if (error) return [];
      const mentions = (data as { mentions?: unknown } | null)?.mentions;
      if (!Array.isArray(mentions)) return [];
      lists.push(mentions);
    }
    return selectQuotes(lists, currentNotebookId);
  } catch {
    return [];
  }
}

export const RETRIEVE_MEMORY_CONTRACT_VERSION = 1 as const;

export type RetrieveMemoryResponseV1 = {
  version: typeof RETRIEVE_MEMORY_CONTRACT_VERSION;
  context: string;
  entityIds: string[];
};

export function isRetrieveMemoryResponseV1(
  value: unknown,
): value is RetrieveMemoryResponseV1 {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const response = value as Record<string, unknown>;
  return response.version === RETRIEVE_MEMORY_CONTRACT_VERSION &&
    typeof response.context === "string" &&
    Array.isArray(response.entityIds) &&
    response.entityIds.every((id) => typeof id === "string");
}

export function retrieveMemoryResponseV1(
  context: string,
  entityIds: string[],
): RetrieveMemoryResponseV1 {
  const response: RetrieveMemoryResponseV1 = {
    version: RETRIEVE_MEMORY_CONTRACT_VERSION,
    context,
    entityIds,
  };
  if (!isRetrieveMemoryResponseV1(response)) {
    throw new TypeError("Invalid retrieve-memory v1 response");
  }
  return response;
}

// ── v2: user-scope retrieval with the user's own past words ──
//
// Quotes are a separate field, never folded into `context`: context is the
// model's private planning packet (entities + relations only), while quotes
// are short, dated, verbatim lines the model may echo back and the app can
// cite by id.

export const RETRIEVE_MEMORY_CONTRACT_VERSION_V2 = 2 as const;
export const MAX_QUOTES = 3;
export const MAX_QUOTE_CHARS = 280;

export type MemoryQuote = {
  entryId: string;
  notebookId: string;
  /** Best-effort (text-matched by LM-06); null for older notebooks. */
  turnId: string | null;
  spokenAt: string | null;
  createdAt: string;
  notebookTitle: string;
  text: string;
};

export type RetrieveMemoryResponseV2 = {
  version: typeof RETRIEVE_MEMORY_CONTRACT_VERSION_V2;
  context: string;
  entityIds: string[];
  quotes: MemoryQuote[];
};

const isNullableString = (value: unknown) => value === null || typeof value === "string";

export function isMemoryQuote(value: unknown): value is MemoryQuote {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const quote = value as Record<string, unknown>;
  return typeof quote.entryId === "string" &&
    typeof quote.notebookId === "string" &&
    isNullableString(quote.turnId) &&
    isNullableString(quote.spokenAt) &&
    typeof quote.createdAt === "string" &&
    typeof quote.notebookTitle === "string" &&
    typeof quote.text === "string" &&
    quote.text.length <= MAX_QUOTE_CHARS;
}

export function isRetrieveMemoryResponseV2(
  value: unknown,
): value is RetrieveMemoryResponseV2 {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const response = value as Record<string, unknown>;
  return response.version === RETRIEVE_MEMORY_CONTRACT_VERSION_V2 &&
    typeof response.context === "string" &&
    Array.isArray(response.entityIds) &&
    response.entityIds.every((id) => typeof id === "string") &&
    Array.isArray(response.quotes) &&
    response.quotes.length <= MAX_QUOTES &&
    response.quotes.every(isMemoryQuote);
}

export function retrieveMemoryResponseV2(
  context: string,
  entityIds: string[],
  quotes: MemoryQuote[],
): RetrieveMemoryResponseV2 {
  const response: RetrieveMemoryResponseV2 = {
    version: RETRIEVE_MEMORY_CONTRACT_VERSION_V2,
    context,
    entityIds,
    quotes,
  };
  if (!isRetrieveMemoryResponseV2(response)) {
    throw new TypeError("Invalid retrieve-memory v2 response");
  }
  return response;
}

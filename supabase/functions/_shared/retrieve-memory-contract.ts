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

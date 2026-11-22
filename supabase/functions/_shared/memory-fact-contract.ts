// The fact layer's read shape (EC-02, contracts/memory-fact-v1.schema.json).
// get_memory_fact returns { fact }, get_memory_fact_history returns { facts }.

export const FACT_STATUSES = ["confirmed", "proposed", "cancelled"] as const;
export const FACT_PROVENANCES = ["extracted", "user_corrected"] as const;

export type MemoryFact = {
  id: string;
  entityId: string;
  attribute: string;
  valueNum: number | null;
  valueText: string | null;
  unit: string | null;
  status: typeof FACT_STATUSES[number];
  eventAt: string | null;
  statedAt: string;
  supersedesFactId: string | null;
  provenance: typeof FACT_PROVENANCES[number];
  sourceNotebookId: string | null;
  sourceEntryId: string | null;
};

const isDate = (value: unknown) =>
  typeof value === "string" && Number.isFinite(Date.parse(value));
const nullableString = (value: unknown) => value === null || typeof value === "string";

export function isMemoryFact(value: unknown): value is MemoryFact {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const f = value as Record<string, unknown>;
  return typeof f.id === "string" && f.id.length > 0 &&
    typeof f.entityId === "string" && f.entityId.length > 0 &&
    typeof f.attribute === "string" && f.attribute.length > 0 &&
    f.attribute === f.attribute.trim().toLowerCase() &&
    (f.valueNum === null || (typeof f.valueNum === "number" && Number.isFinite(f.valueNum))) &&
    nullableString(f.valueText) && nullableString(f.unit) &&
    (f.valueNum !== null || (typeof f.valueText === "string" && f.valueText.length > 0)) &&
    (FACT_STATUSES as readonly unknown[]).includes(f.status) &&
    (f.eventAt === null || isDate(f.eventAt)) && isDate(f.statedAt) &&
    nullableString(f.supersedesFactId) &&
    (FACT_PROVENANCES as readonly unknown[]).includes(f.provenance) &&
    nullableString(f.sourceNotebookId) && nullableString(f.sourceEntryId);
}

export function isMemoryFactResult(value: unknown): value is { fact: MemoryFact | null } {
  if (!value || typeof value !== "object") return false;
  const fact = (value as { fact?: unknown }).fact;
  return fact === null || isMemoryFact(fact);
}

export function isMemoryFactHistory(value: unknown): value is { facts: MemoryFact[] } {
  if (!value || typeof value !== "object") return false;
  const facts = (value as { facts?: unknown }).facts;
  return Array.isArray(facts) && facts.every(isMemoryFact);
}

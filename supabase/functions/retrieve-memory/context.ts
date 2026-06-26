import type { RetrievalResult } from "../_shared/graphloop/types.ts";

/**
 * Build the LLM-facing context from a RetrievalResult using entities + relations
 * ONLY. graphloop's own packContext appends verbatim journal entries as a
 * "## Sources" section; we never emit that. When there are no seed entities,
 * retrieve() returns a source-free global/community context which we pass through.
 */
export function buildContext(result: RetrievalResult): string {
  if (result.entities.length === 0) return result.context; // global/empty: source-free by construction
  const byId = new Map(result.entities.map((e) => [e.id, e]));
  const out: string[] = ["## Entities"];
  for (const e of result.entities) {
    const desc = e.description ? `: ${e.description}` : "";
    out.push(`- ${e.name} (${e.type})${desc} [mentions: ${e.mentions}]`);
  }
  if (result.relations.length) {
    out.push("## Relations");
    for (const r of result.relations) {
      const s = byId.get(r.source)?.name ?? r.source;
      const t = byId.get(r.target)?.name ?? r.target;
      out.push(`- ${s} --${r.label}--> ${t}`);
    }
  }
  return out.join("\n");
}

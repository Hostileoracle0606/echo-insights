import Graph from "graphology";
import louvain from "graphology-communities-louvain";
import type { CommunitySummary, GraphState } from "./types.ts";
import { activeRelations } from "./graph-ops.ts";

export function buildCommunities(state: GraphState): CommunitySummary[] {
  const active = activeRelations(state);
  if (active.length === 0) return [];

  const g = new Graph({ type: "undirected", multi: false, allowSelfLoops: false });
  for (const r of active) {
    if (!g.hasNode(r.source)) g.addNode(r.source);
    if (!g.hasNode(r.target)) g.addNode(r.target);
    if (r.source !== r.target && !g.hasEdge(r.source, r.target)) g.addEdge(r.source, r.target);
  }

  const partition = louvain(g) as Record<string, number>;
  const groups = new Map<number, string[]>();
  for (const [nodeId, cid] of Object.entries(partition)) {
    if (!groups.has(cid)) groups.set(cid, []);
    groups.get(cid)!.push(nodeId);
  }

  const summaries: CommunitySummary[] = [];
  for (const [cid, ids] of groups) {
    const ranked = ids
      .map((id) => ({ id, mentions: state.entities[id]?.mentions ?? 0, degree: g.degree(id) }))
      .sort((a, b) => b.degree - a.degree || b.mentions - a.mentions);
    const topEntities = ranked.slice(0, 5).map((r) => state.entities[r.id]?.name ?? r.id);
    summaries.push({
      id: cid,
      label: topEntities.slice(0, 3).join(", "),
      entityIds: ranked.map((r) => r.id),
      size: ids.length,
      topEntities,
    });
  }
  return summaries.sort((a, b) => b.size - a.size);
}

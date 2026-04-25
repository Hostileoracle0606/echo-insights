import type { JournalState, Entity, Relation } from "./journal-types";

function entityNoteFilename(e: Entity): string {
  return `${e.name.replace(/[\\/:*?"<>|]/g, "-")}.md`;
}

function frontmatter(obj: Record<string, unknown>): string {
  const lines = ["---"];
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null || v === "") continue;
    if (Array.isArray(v)) {
      if (v.length === 0) continue;
      lines.push(`${k}:`);
      v.forEach((x) => lines.push(`  - ${String(x).replace(/\n/g, " ")}`));
    } else if (typeof v === "object") {
      lines.push(`${k}:`);
      for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) {
        lines.push(`  ${k2}: ${String(v2).replace(/\n/g, " ")}`);
      }
    } else {
      lines.push(`${k}: ${String(v).replace(/\n/g, " ")}`);
    }
  }
  lines.push("---");
  return lines.join("\n");
}

function entityToMarkdown(
  e: Entity,
  outgoing: Relation[],
  incoming: Relation[],
  byId: Record<string, Entity>,
): string {
  const fm = frontmatter({
    id: e.id,
    type: e.type,
    mentions: e.mentions,
    firstSeen: e.firstSeen,
    lastSeen: e.lastSeen,
    metadata: e.metadata,
    aliases: [],
  });

  const sections: string[] = [fm, "", `# ${e.name}`, ""];
  if (e.description) sections.push(e.description, "");

  if (outgoing.length) {
    sections.push("## Connections");
    outgoing.forEach((r) => {
      const t = byId[r.target];
      if (t) sections.push(`- **${r.label.replace(/_/g, " ")}** → [[${t.name}]]`);
    });
    sections.push("");
  }
  if (incoming.length) {
    sections.push("## Mentioned by");
    incoming.forEach((r) => {
      const s = byId[r.source];
      if (s) sections.push(`- [[${s.name}]] — ${r.label.replace(/_/g, " ")}`);
    });
    sections.push("");
  }
  return sections.join("\n");
}

export async function exportToObsidianZip(state: JournalState): Promise<Blob> {
  const { default: JSZip } = await import("jszip");
  const zip = new JSZip();
  const root = zip.folder("Lumen Vault")!;
  const entitiesFolder = root.folder("Entities")!;
  const journalFolder = root.folder("Journal")!;

  const allRelations = Object.values(state.relations);
  const byId = state.entities;

  for (const e of Object.values(state.entities)) {
    const outgoing = allRelations.filter((r) => r.source === e.id);
    const incoming = allRelations.filter((r) => r.target === e.id);
    entitiesFolder.file(entityNoteFilename(e), entityToMarkdown(e, outgoing, incoming, byId));
  }

  // Journal entries
  for (const entry of state.entries) {
    const date = new Date(entry.createdAt);
    const fname = `${date.toISOString().slice(0, 10)}-${entry.id}.md`;
    const linked = entry.entityIds
      .map((id) => byId[id])
      .filter(Boolean)
      .map((e) => `[[${e!.name}]]`)
      .join(", ");
    const fm = frontmatter({
      id: entry.id,
      createdAt: entry.createdAt,
      entities: entry.entityIds.map((id) => byId[id]?.name).filter(Boolean),
    });
    const md = [
      fm, "",
      `# Journal — ${date.toLocaleString()}`,
      "",
      entry.text,
      "",
      linked ? `**Mentions:** ${linked}` : "",
    ].join("\n");
    journalFolder.file(fname, md);
  }

  // Index
  const index = [
    "# Lumen Vault",
    "",
    `Exported ${new Date().toLocaleString()} — ${Object.keys(state.entities).length} entities, ${Object.keys(state.relations).length} relations, ${state.entries.length} entries.`,
    "",
    "## Entities",
    ...Object.values(state.entities)
      .sort((a, b) => b.mentions - a.mentions)
      .map((e) => `- [[${e.name}]] _(${e.type}, ${e.mentions} mentions)_`),
  ].join("\n");
  root.file("README.md", index);

  return zip.generateAsync({ type: "blob" });
}

export function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

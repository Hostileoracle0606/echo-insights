import type { JournalEntry, JournalState, Entity, Relation } from "./journal-types";

/**
 * Obsidian export shape (post wiki-mode redesign):
 *
 *   Lumen Vault/
 *     README.md            ← MOC: recent days + entities grouped by type
 *     Maya.md              ← entities at root (clean [[wikilinks]])
 *     CS246.md
 *     ...
 *     Daily/
 *       2026-04-26.md      ← one file per day, sections per utterance
 *       2026-04-25.md
 *
 * Why this shape:
 *  - Entities at root: [[Maya]] resolves with no folder prefix; the
 *    quick-switcher treats topics as the primary index.
 *  - Daily notes: matches Obsidian's standard convention; one file per day
 *    instead of one per utterance keeps the vault scannable as the journal
 *    grows. Anchor links ([[2026-04-26#14:32]]) recover per-moment
 *    deep-linking from entity pages.
 *  - README as MOC (Map of Content): grouped-by-type entity index plus a
 *    recent-days list — a real front door, not a dump.
 */

const safeFilename = (name: string): string => name.replace(/[\\/:*?"<>|]/g, "-").trim();

function entityNoteFilename(e: Entity): string {
  return `${safeFilename(e.name)}.md`;
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

/** Local-time YYYY-MM-DD key. Important: NOT toISOString — that uses UTC and
 *  silently splits an evening session across two day-files when the user is
 *  west of Greenwich. */
function dayKey(iso: string): string {
  const d = new Date(iso);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function timeAnchor(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

function snippet(text: string, max = 140): string {
  const trimmed = text.replace(/\s+/g, " ").trim();
  return trimmed.length > max ? `${trimmed.slice(0, max - 1)}…` : trimmed;
}

function entityToMarkdown(
  e: Entity,
  outgoing: Relation[],
  incoming: Relation[],
  recentMentions: JournalEntry[],
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

  // Wiki-mode question backlog: lines of questioning Lumen could pursue.
  // Granular-mode entities have no questions; the section is omitted.
  if (e.questions?.length) {
    sections.push("## Questions to explore");
    e.questions.forEach((q) => sections.push(`- [ ] ${q}`));
    sections.push("");
  }

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

  // Recent mentions: anchored links into Daily notes recover per-moment
  // deep-linking that we lost when we collapsed per-utterance files into
  // daily files. Cap at 5 most recent so entity pages don't grow unbounded.
  if (recentMentions.length) {
    sections.push("## Recent mentions");
    recentMentions.slice(0, 5).forEach((entry) => {
      const date = dayKey(entry.createdAt);
      const time = timeAnchor(entry.createdAt);
      sections.push(`- [[Daily/${date}#${time}|${date} ${time}]] — ${snippet(entry.text)}`);
    });
    sections.push("");
  }

  return sections.join("\n");
}

function dailyNoteMarkdown(
  dateKey: string,
  entries: JournalEntry[],
  byId: Record<string, Entity>,
): string {
  const date = new Date(`${dateKey}T00:00:00`);
  const allEntityNames = Array.from(
    new Set(
      entries
        .flatMap((e) => e.entityIds)
        .map((id) => byId[id]?.name)
        .filter((name): name is string => Boolean(name)),
    ),
  );

  const fm = frontmatter({
    date: dateKey,
    entryCount: entries.length,
    entities: allEntityNames,
  });

  const heading = `# ${date.toLocaleDateString(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  })}`;

  const sections: string[] = [fm, "", heading, ""];

  for (const entry of entries) {
    // Heading is bare time so anchor links stay clean: [[2026-04-26#14:32]].
    sections.push(`## ${timeAnchor(entry.createdAt)}`);
    sections.push("");
    const linked = entry.entityIds
      .map((id) => byId[id]?.name)
      .filter((name): name is string => Boolean(name))
      .map((name) => `[[${name}]]`)
      .join(" · ");
    if (linked) {
      sections.push(linked);
      sections.push("");
    }
    sections.push(entry.text);
    sections.push("");
  }
  return sections.join("\n");
}

const TYPE_ORDER: Array<{ type: Entity["type"]; label: string }> = [
  { type: "person", label: "People" },
  { type: "place", label: "Places" },
  { type: "organization", label: "Organizations" },
  { type: "project", label: "Projects" },
  { type: "event", label: "Events" },
  { type: "activity", label: "Activities" },
  { type: "concept", label: "Concepts" },
  { type: "emotion", label: "Feelings" },
  { type: "other", label: "Other" },
];

export async function exportToObsidianZip(state: JournalState): Promise<Blob> {
  const { default: JSZip } = await import("jszip");
  const zip = new JSZip();
  const root = zip.folder("Lumen Vault")!;
  // No more Entities/ folder — entities go to vault root for clean wikilinks.
  const dailyFolder = root.folder("Daily")!;

  const allRelations = Object.values(state.relations).filter((r) => !r.supersededAt);
  const byId = state.entities;

  // Group entries by local-time day. Reused for both daily-note generation
  // and the README's "Recent days" list, so we build it once.
  const byDay = new Map<string, JournalEntry[]>();
  for (const entry of state.entries) {
    const key = dayKey(entry.createdAt);
    const bucket = byDay.get(key);
    if (bucket) bucket.push(entry);
    else byDay.set(key, [entry]);
  }
  // Sort entries inside each day ascending (chronological within the file).
  for (const list of byDay.values()) {
    list.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  }

  // Per-entity recent mentions: index entries by entity id once so we don't
  // do an O(entries × entities) sweep inside the entity loop.
  const mentionsByEntity = new Map<string, JournalEntry[]>();
  // state.entries comes newest-first from the store; preserve that order so
  // "Recent mentions" actually reads as recent-first.
  for (const entry of state.entries) {
    for (const id of entry.entityIds) {
      const list = mentionsByEntity.get(id);
      if (list) list.push(entry);
      else mentionsByEntity.set(id, [entry]);
    }
  }

  // Entities at vault root.
  for (const e of Object.values(state.entities)) {
    const outgoing = allRelations.filter((r) => r.source === e.id);
    const incoming = allRelations.filter((r) => r.target === e.id);
    const mentions = mentionsByEntity.get(e.id) ?? [];
    root.file(entityNoteFilename(e), entityToMarkdown(e, outgoing, incoming, mentions, byId));
  }

  // Daily notes — one file per day, all entries collapsed into time-headed sections.
  for (const [date, entries] of byDay.entries()) {
    dailyFolder.file(`${date}.md`, dailyNoteMarkdown(date, entries, byId));
  }

  // README as Map of Content: recent days + entities grouped by type.
  const entitiesByType = new Map<Entity["type"], Entity[]>();
  for (const e of Object.values(state.entities)) {
    const list = entitiesByType.get(e.type);
    if (list) list.push(e);
    else entitiesByType.set(e.type, [e]);
  }

  const recentDays = Array.from(byDay.keys())
    .sort((a, b) => b.localeCompare(a))
    .slice(0, 14);

  const indexLines: string[] = [
    "# Lumen Vault",
    "",
    `Exported ${new Date().toLocaleString()} — ${Object.keys(state.entities).length} entities, ${Object.keys(state.relations).length} relations, ${state.entries.length} entries across ${byDay.size} day(s).`,
    "",
  ];

  if (recentDays.length) {
    indexLines.push("## Recent days", "");
    for (const date of recentDays) {
      const count = byDay.get(date)?.length ?? 0;
      indexLines.push(
        `- [[Daily/${date}|${date}]] _(${count} ${count === 1 ? "entry" : "entries"})_`,
      );
    }
    indexLines.push("");
  }

  for (const { type, label } of TYPE_ORDER) {
    const list = (entitiesByType.get(type) ?? []).slice().sort((a, b) => b.mentions - a.mentions);
    if (!list.length) continue;
    indexLines.push(`## ${label}`, "");
    for (const e of list) {
      indexLines.push(
        `- [[${e.name}]] _(${e.mentions} ${e.mentions === 1 ? "mention" : "mentions"})_`,
      );
    }
    indexLines.push("");
  }

  root.file("README.md", indexLines.join("\n"));

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

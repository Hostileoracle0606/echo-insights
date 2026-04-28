import type { Entity, Relation } from "@/lib/journal-types";
import { cn } from "@/lib/utils";

interface Props {
  entities: Entity[];
  relations: Relation[];
  highlightId?: string | null;
  activeEntityIds?: string[];
  activeRelationIds?: string[];
  onSelect?: (id: string) => void;
  className?: string;
}

const TYPE_DOT: Record<string, string> = {
  person: "bg-[oklch(0.7_0.15_50)]",
  place: "bg-[oklch(0.62_0.1_160)]",
  organization: "bg-[oklch(0.55_0.13_290)]",
  project: "bg-[oklch(0.72_0.14_85)]",
  event: "bg-[oklch(0.62_0.16_30)]",
  concept: "bg-[oklch(0.55_0.13_240)]",
  emotion: "bg-[oklch(0.62_0.16_350)]",
  object: "bg-[oklch(0.6_0.02_60)]",
  other: "bg-[oklch(0.6_0.02_60)]",
};

export function EntityList({
  entities,
  relations,
  highlightId,
  activeEntityIds = [],
  activeRelationIds = [],
  onSelect,
  className,
}: Props) {
  const activeEntitySet = new Set(activeEntityIds);
  const activeRelationSet = new Set(activeRelationIds);

  if (entities.length === 0) {
    return (
      <div
        className={cn(
          "flex h-[480px] items-center justify-center rounded-lg border bg-card text-sm text-muted-foreground",
          className,
        )}
      >
        Entities will appear here as you speak.
      </div>
    );
  }
  const sorted = [...entities].sort((a, b) => b.mentions - a.mentions);
  const byId = Object.fromEntries(entities.map((e) => [e.id, e]));

  return (
    <div className={cn("h-[480px] overflow-y-auto rounded-lg border bg-card", className)}>
      <ul className="divide-y">
        {sorted.map((e) => {
          const out = relations.filter((r) => r.source === e.id);
          const isHi = highlightId === e.id;
          const isActive = activeEntitySet.has(e.id);
          return (
            <li
              key={e.id}
              className={cn(
                "group cursor-pointer px-4 py-3 transition-colors hover:bg-muted/60",
                isHi && "bg-amber-soft/40",
                isActive && "upsert-pop bg-accent/10",
              )}
              onClick={() => onSelect?.(e.id)}
            >
              <div className="flex items-center gap-2">
                <span
                  className={`inline-block h-2.5 w-2.5 rounded-full ${TYPE_DOT[e.type] ?? TYPE_DOT.other}`}
                />
                <span className="font-display text-base text-foreground">{e.name}</span>
                <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
                  {e.type}
                </span>
                <span className="ml-auto text-xs text-muted-foreground">{e.mentions}x</span>
              </div>
              {e.description && (
                <p className="mt-1 text-sm text-muted-foreground line-clamp-2">{e.description}</p>
              )}
              {out.length > 0 && (
                <div className="mt-1.5 flex flex-wrap gap-1.5">
                  {out.slice(0, 6).map((r) => (
                    <span
                      key={r.id}
                      className={cn(
                        "rounded-full border bg-background px-2 py-0.5 text-[11px] text-muted-foreground",
                        activeRelationSet.has(r.id) && "border-accent bg-accent/10 text-foreground",
                      )}
                    >
                      <span className="text-foreground/80">{r.label.replace(/_/g, " ")}</span>
                      {" -> "}
                      <span className="font-medium text-foreground">
                        {byId[r.target]?.name ?? r.target}
                      </span>
                    </span>
                  ))}
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

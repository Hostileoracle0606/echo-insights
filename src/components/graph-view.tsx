import { useEffect, useMemo, useRef, useState } from "react";
import type { Entity, Relation, EntityType } from "@/lib/journal-types";

interface Props {
  entities: Entity[];
  relations: Relation[];
  highlightId?: string | null;
  onSelect?: (id: string) => void;
}

const TYPE_COLORS: Record<EntityType, string> = {
  person: "#c97b3a",
  place: "#5b8a72",
  organization: "#7a6dc4",
  project: "#c0a040",
  event: "#cf6a52",
  concept: "#4a7ab8",
  emotion: "#b85a8a",
  object: "#7a7a7a",
  other: "#8a8a8a",
};

export function GraphView({ entities, relations, highlightId, onSelect }: Props) {
  const [Comp, setComp] = useState<any>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [size, setSize] = useState({ w: 600, h: 480 });

  useEffect(() => {
    let mounted = true;
    import("react-force-graph-2d").then((m) => { if (mounted) setComp(() => m.default); });
    return () => { mounted = false; };
  }, []);

  useEffect(() => {
    if (!containerRef.current) return;
    const el = containerRef.current;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      setSize({ w: Math.max(320, Math.floor(r.width)), h: Math.max(360, Math.floor(r.height)) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const data = useMemo(() => ({
    nodes: entities.map((e) => ({
      id: e.id,
      name: e.name,
      type: e.type,
      val: 1 + Math.log2(1 + e.mentions) * 3,
      color: TYPE_COLORS[e.type] ?? TYPE_COLORS.other,
    })),
    links: relations
      .filter((r) => entities.find((e) => e.id === r.source) && entities.find((e) => e.id === r.target))
      .map((r) => ({ source: r.source, target: r.target, label: r.label })),
  }), [entities, relations]);

  return (
    <div ref={containerRef} className="relative h-[480px] w-full overflow-hidden rounded-lg border bg-card">
      {!Comp || entities.length === 0 ? (
        <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
          {entities.length === 0 ? "Your graph will appear here as you speak." : "Loading graph…"}
        </div>
      ) : (
        <Comp
          graphData={data}
          width={size.w}
          height={size.h}
          backgroundColor="transparent"
          nodeRelSize={5}
          linkColor={() => "rgba(120,100,80,0.35)"}
          linkDirectionalArrowLength={4}
          linkDirectionalArrowRelPos={0.85}
          linkWidth={1}
          cooldownTicks={80}
          onNodeClick={(n: any) => onSelect?.(n.id)}
          nodeCanvasObject={(node: any, ctx: any, globalScale: number) => {
            const label = node.name as string;
            const fontSize = 11 / Math.max(0.6, globalScale);
            const r = 4 + Math.log2(1 + (node.val ?? 1)) * 2;
            const isHi = highlightId === node.id;
            ctx.beginPath();
            ctx.arc(node.x, node.y, r, 0, Math.PI * 2, false);
            ctx.fillStyle = node.color;
            ctx.fill();
            if (isHi) {
              ctx.lineWidth = 2 / globalScale;
              ctx.strokeStyle = "#1a1208";
              ctx.stroke();
            }
            ctx.font = `${fontSize}px Inter, sans-serif`;
            ctx.fillStyle = "#1a1208";
            ctx.textAlign = "center";
            ctx.textBaseline = "top";
            ctx.fillText(label, node.x, node.y + r + 2);
          }}
        />
      )}
      <div className="pointer-events-none absolute bottom-2 left-2 flex flex-wrap gap-2 text-[10px] uppercase tracking-wider text-muted-foreground">
        {Object.entries(TYPE_COLORS).slice(0, 6).map(([t, c]) => (
          <span key={t} className="flex items-center gap-1">
            <span className="inline-block h-2 w-2 rounded-full" style={{ background: c }} />{t}
          </span>
        ))}
      </div>
    </div>
  );
}

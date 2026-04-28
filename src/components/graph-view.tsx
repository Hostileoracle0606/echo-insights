import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type ComponentType,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { forceX, forceY } from "d3-force-3d";
import type { Entity, Relation, EntityType } from "@/lib/journal-types";
import { cn } from "@/lib/utils";

export interface GraphLayoutSnapshot {
  /** Graph-coord positions for every laid-out node, keyed by entity id. */
  positions: Record<string, { x: number; y: number }>;
  /** Axis-aligned bounding box of all node positions in graph coords. */
  bounds: { minX: number; maxX: number; minY: number; maxY: number };
}

export interface GraphViewport {
  /** Graph-coord position currently at the center of the canvas. */
  cx: number;
  cy: number;
  /** d3-zoom scale: pixels-per-graph-unit. */
  k: number;
  /** Canvas pixel size (matches the FG canvas, not the container box). */
  w: number;
  h: number;
}

interface Props {
  entities: Entity[];
  relations: Relation[];
  highlightId?: string | null;
  activeEntityIds?: string[];
  activeRelationIds?: string[];
  onSelect?: (id: string) => void;
  /** Fires after every settled-enough simulation tick — drives the minimap. */
  onLayoutChange?: (layout: GraphLayoutSnapshot) => void;
  /** Fires whenever the user pans/zooms — drives the minimap viewport rect. */
  onViewportChange?: (vp: GraphViewport) => void;
  className?: string;
}

const TYPE_COLORS: Record<EntityType, string> = {
  person: "#c97b3a",
  place: "#5b8a72",
  organization: "#7a6dc4",
  project: "#c0a040",
  event: "#cf6a52",
  activity: "#4aa39e",
  concept: "#4a7ab8",
  emotion: "#b85a8a",
  other: "#8a8a8a",
};

// Symbolic pictograms — each entity type gets a glyph that *depicts* the thing
// it stands for. Concept (lightbulb) and "other" (ellipsis) are abstract by
// nature; the rest are literal silhouettes. Glyphs are drawn on top of a
// solid colored sphere; `negative` is the sphere's color, used inside cutouts
// (windows, pin-hole, etc.) so the sphere shows through.
//
// All glyphs are sized to fit within a circle of radius r centered at (x, y).

function drawNodeIcon(
  ctx: CanvasRenderingContext2D,
  type: EntityType,
  x: number,
  y: number,
  r: number,
  fill: string,
  negative: string,
) {
  ctx.fillStyle = fill;
  switch (type) {
    case "person": {
      // Head + shoulder silhouette (Lucide "User")
      ctx.beginPath();
      ctx.arc(x, y - r * 0.32, r * 0.36, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(x - r * 0.78, y + r * 0.7);
      ctx.quadraticCurveTo(x, y - r * 0.05, x + r * 0.78, y + r * 0.7);
      ctx.closePath();
      ctx.fill();
      return;
    }
    case "place": {
      // Map pin: round head tapering to a point, with hole punched in head
      const headR = r * 0.55;
      const headY = y - r * 0.2;
      const tipY = y + r * 0.95;
      ctx.beginPath();
      ctx.moveTo(x + headR, headY);
      // Top half of head circle (anticlockwise = visually over the top)
      ctx.arc(x, headY, headR, 0, Math.PI, true);
      ctx.quadraticCurveTo(x - r * 0.55, y + r * 0.35, x, tipY);
      ctx.quadraticCurveTo(x + r * 0.55, y + r * 0.35, x + headR, headY);
      ctx.closePath();
      ctx.fill();
      // Inner hole
      ctx.fillStyle = negative;
      ctx.beginPath();
      ctx.arc(x, headY, headR * 0.36, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    case "organization": {
      // Building: rectangle with 2×2 window cutouts and a door
      const w = r * 1.45;
      const h = r * 1.7;
      ctx.fillRect(x - w / 2, y - h / 2, w, h);
      ctx.fillStyle = negative;
      const ww = r * 0.22;
      const wh = r * 0.28;
      const wins: Array<[number, number]> = [
        [-r * 0.38, -r * 0.42],
        [r * 0.38, -r * 0.42],
        [-r * 0.38, r * 0.05],
        [r * 0.38, r * 0.05],
      ];
      for (const [dx, dy] of wins) {
        ctx.fillRect(x + dx - ww / 2, y + dy - wh / 2, ww, wh);
      }
      ctx.fillRect(x - r * 0.16, y + r * 0.4, r * 0.32, r * 0.45);
      return;
    }
    case "project": {
      // Clipboard: body, top clip tab, three text lines
      const w = r * 1.25;
      const h = r * 1.7;
      const top = y - h / 2 + r * 0.18;
      ctx.fillRect(x - w / 2, top, w, h - r * 0.18);
      const cw = r * 0.65;
      const ch = r * 0.4;
      ctx.fillRect(x - cw / 2, y - h / 2, cw, ch);
      ctx.fillStyle = negative;
      ctx.fillRect(x - r * 0.45, y - r * 0.05, r * 0.9, r * 0.1);
      ctx.fillRect(x - r * 0.45, y + r * 0.25, r * 0.7, r * 0.1);
      ctx.fillRect(x - r * 0.45, y + r * 0.55, r * 0.85, r * 0.1);
      return;
    }
    case "event": {
      // Calendar: body + two binding pegs on top + header strip
      const w = r * 1.5;
      const h = r * 1.5;
      const top = y - h / 2 + r * 0.15;
      ctx.fillRect(x - w / 2, top, w, h - r * 0.15);
      const pegW = r * 0.18;
      const pegH = r * 0.45;
      ctx.fillRect(x - r * 0.45 - pegW / 2, top - r * 0.3, pegW, pegH);
      ctx.fillRect(x + r * 0.45 - pegW / 2, top - r * 0.3, pegW, pegH);
      ctx.fillStyle = negative;
      ctx.fillRect(x - w / 2 + r * 0.1, top + r * 0.18, w - r * 0.2, r * 0.12);
      return;
    }
    case "activity": {
      // EKG / sparkline (stroked) — Lucide "Activity"
      ctx.strokeStyle = fill;
      ctx.lineWidth = Math.max(2, r * 0.42);
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.beginPath();
      ctx.moveTo(x - r * 0.95, y);
      ctx.lineTo(x - r * 0.45, y);
      ctx.lineTo(x - r * 0.2, y - r * 0.65);
      ctx.lineTo(x + r * 0.1, y + r * 0.65);
      ctx.lineTo(x + r * 0.4, y);
      ctx.lineTo(x + r * 0.95, y);
      ctx.stroke();
      return;
    }
    case "concept": {
      // Lightbulb — abstract by necessity, but iconic for "idea"
      ctx.beginPath();
      ctx.arc(x, y - r * 0.18, r * 0.55, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillRect(x - r * 0.25, y + r * 0.4, r * 0.5, r * 0.32);
      ctx.fillStyle = negative;
      ctx.fillRect(x - r * 0.3, y + r * 0.36, r * 0.6, r * 0.06);
      ctx.fillRect(x - r * 0.22, y + r * 0.55, r * 0.44, r * 0.04);
      return;
    }
    case "emotion": {
      // Heart silhouette
      ctx.beginPath();
      const bottom = y + r * 0.85;
      const top = y - r * 0.2;
      ctx.moveTo(x, bottom);
      ctx.bezierCurveTo(x - r * 1.3, y - r * 0.1, x - r * 0.55, y - r, x, top);
      ctx.bezierCurveTo(x + r * 0.55, y - r, x + r * 1.3, y - r * 0.1, x, bottom);
      ctx.closePath();
      ctx.fill();
      return;
    }
    case "other": {
      // Three-dot ellipsis — unclassified / "more" bucket
      const dr = r * 0.18;
      ctx.fillStyle = fill;
      for (const dx of [-r * 0.55, 0, r * 0.55]) {
        ctx.beginPath();
        ctx.arc(x + dx, y, dr, 0, Math.PI * 2);
        ctx.fill();
      }
      return;
    }
  }
}

// Returns the inner SVG geometry for a symbol, sized to ±1 bounds.
// `fill` is the symbol's positive-space color; `negative` is the cutout color
// (drawn over the silhouette to "punch holes").
function renderSymbolPaths(type: EntityType, fill: string, negative: string) {
  switch (type) {
    case "person":
      return (
        <>
          <circle cx={0} cy={-0.32} r={0.36} fill={fill} />
          <path d="M -0.78 0.7 Q 0 -0.05 0.78 0.7 Z" fill={fill} />
        </>
      );
    case "place":
      return (
        <>
          <path
            d="M 0.55 -0.2 A 0.55 0.55 0 1 0 -0.55 -0.2 Q -0.55 0.35 0 0.95 Q 0.55 0.35 0.55 -0.2 Z"
            fill={fill}
          />
          <circle cx={0} cy={-0.2} r={0.2} fill={negative} />
        </>
      );
    case "organization": {
      const w = 1.45;
      const h = 1.7;
      const ww = 0.22;
      const wh = 0.28;
      const wins: Array<[number, number]> = [
        [-0.38, -0.42],
        [0.38, -0.42],
        [-0.38, 0.05],
        [0.38, 0.05],
      ];
      return (
        <>
          <rect x={-w / 2} y={-h / 2} width={w} height={h} fill={fill} />
          {wins.map(([dx, dy], i) => (
            <rect key={i} x={dx - ww / 2} y={dy - wh / 2} width={ww} height={wh} fill={negative} />
          ))}
          <rect x={-0.16} y={0.4} width={0.32} height={0.45} fill={negative} />
        </>
      );
    }
    case "project": {
      const w = 1.25;
      const h = 1.7;
      const top = -h / 2 + 0.18;
      const cw = 0.65;
      const ch = 0.4;
      return (
        <>
          <rect x={-w / 2} y={top} width={w} height={h - 0.18} fill={fill} />
          <rect x={-cw / 2} y={-h / 2} width={cw} height={ch} fill={fill} />
          <rect x={-0.45} y={-0.05} width={0.9} height={0.1} fill={negative} />
          <rect x={-0.45} y={0.25} width={0.7} height={0.1} fill={negative} />
          <rect x={-0.45} y={0.55} width={0.85} height={0.1} fill={negative} />
        </>
      );
    }
    case "event": {
      const w = 1.5;
      const h = 1.5;
      const top = -h / 2 + 0.15;
      return (
        <>
          <rect x={-w / 2} y={top} width={w} height={h - 0.15} fill={fill} />
          <rect x={-0.45 - 0.09} y={top - 0.3} width={0.18} height={0.45} fill={fill} />
          <rect x={0.45 - 0.09} y={top - 0.3} width={0.18} height={0.45} fill={fill} />
          <rect x={-w / 2 + 0.1} y={top + 0.18} width={w - 0.2} height={0.12} fill={negative} />
        </>
      );
    }
    case "activity":
      return (
        <path
          d="M -0.95 0 L -0.45 0 L -0.2 -0.65 L 0.1 0.65 L 0.4 0 L 0.95 0"
          fill="none"
          stroke={fill}
          strokeWidth={0.32}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      );
    case "concept":
      return (
        <>
          <circle cx={0} cy={-0.18} r={0.55} fill={fill} />
          <rect x={-0.25} y={0.4} width={0.5} height={0.32} fill={fill} />
          <rect x={-0.3} y={0.36} width={0.6} height={0.06} fill={negative} />
          <rect x={-0.22} y={0.55} width={0.44} height={0.04} fill={negative} />
        </>
      );
    case "emotion":
      return (
        <path
          d="M 0 0.85 C -1.3 -0.1, -0.55 -1, 0 -0.2 C 0.55 -1, 1.3 -0.1, 0 0.85 Z"
          fill={fill}
        />
      );
    case "other":
      return (
        <>
          <circle cx={-0.55} cy={0} r={0.18} fill={fill} />
          <circle cx={0} cy={0} r={0.18} fill={fill} />
          <circle cx={0.55} cy={0} r={0.18} fill={fill} />
        </>
      );
  }
}

// Each node — both in the graph and in the legend — is a solid colored sphere
// with the symbol layered on top in the card color. Cutouts inside the symbol
// (windows, pin-hole, etc.) re-expose the sphere underneath.
export function NodeGlyph({ type, size = 14 }: { type: EntityType; size?: number }) {
  const sphereColor = TYPE_COLORS[type];
  return (
    <svg
      viewBox="-1 -1 2 2"
      width={size}
      height={size}
      aria-hidden="true"
      style={{ display: "block" }}
    >
      <circle cx={0} cy={0} r={0.95} fill={sphereColor} />
      <g transform="scale(0.62)">{renderSymbolPaths(type, "var(--card)", sphereColor)}</g>
    </svg>
  );
}

// Hand-placed constellation of 7 entity-type glyphs — used by both the empty
// hero on the main canvas and the empty Overview minimap, so both reinforce
// the same "this is what your graph will become" preview at different scales.
const GHOST_GLYPHS: Array<{ type: EntityType; cx: number; cy: number }> = [
  { type: "person", cx: 90, cy: 70 },
  { type: "event", cx: 310, cy: 55 },
  { type: "concept", cx: 200, cy: 135 },
  { type: "place", cx: 340, cy: 165 },
  { type: "emotion", cx: 65, cy: 200 },
  { type: "activity", cx: 175, cy: 235 },
  { type: "project", cx: 295, cy: 230 },
];
// Sparse relation set — enough to imply structure without becoming a mesh.
const GHOST_LINKS: Array<[number, number]> = [
  [0, 2], // person — concept
  [0, 4], // person — emotion
  [2, 3], // concept — place
  [2, 5], // concept — activity
  [1, 3], // event — place
  [4, 5], // emotion — activity
  [5, 6], // activity — project
];

// Reusable constellation SVG. Same viewBox at all sizes — SVG's intrinsic
// scaling means the strokes and glyphs scale proportionally with the
// rendered container (small in minimap, large in main hero).
function GhostConstellationSvg({ className }: { className?: string }) {
  const r = 18;
  return (
    <svg
      viewBox="0 0 400 290"
      className={cn("h-full w-full", className)}
      preserveAspectRatio="xMidYMid meet"
      aria-hidden="true"
    >
      <g stroke="currentColor" strokeWidth={0.6} className="text-foreground/50">
        {GHOST_LINKS.map(([a, b], i) => (
          <line
            key={i}
            x1={GHOST_GLYPHS[a].cx}
            y1={GHOST_GLYPHS[a].cy}
            x2={GHOST_GLYPHS[b].cx}
            y2={GHOST_GLYPHS[b].cy}
          />
        ))}
      </g>
      {GHOST_GLYPHS.map((g, i) => (
        <g key={i} transform={`translate(${g.cx} ${g.cy})`}>
          <circle r={r * 0.95} fill={TYPE_COLORS[g.type]} />
          <g transform={`scale(${r * 0.62})`}>
            {renderSymbolPaths(g.type, "var(--card)", TYPE_COLORS[g.type])}
          </g>
        </g>
      ))}
    </svg>
  );
}

// Empty hero on the main canvas: faint ghost constellation + an Overview-style
// label underneath. The label uses the same uppercase tracking-[0.22em] voice
// as the sidebar's "Overview" / "Key" chrome labels — reads as system, not
// editorial — so the empty state feels like a unified section header.
function GraphGhost() {
  return (
    <div className="ink-rise flex h-full flex-col items-center justify-end px-10 pb-28 lg:px-16 lg:pb-32">
      <div className="w-full max-w-xl" style={{ opacity: 0.3 }}>
        <GhostConstellationSvg />
      </div>
      <p className="mt-4 text-sm font-light uppercase tracking-[0.32em] text-muted-foreground/50">
        Your graph will appear here
      </p>
    </div>
  );
}

type ForceGraphNode = {
  id: string;
  name: string;
  type: EntityType;
  val: number;
  color: string;
  x?: number;
  y?: number;
};

type ForceGraphLink = {
  id: string;
};

type ForceGraphProps = Record<string, unknown>;

type ForceGraphHandle = {
  // Two arities: read a force (`d3Force(name)`) or install one
  // (`d3Force(name, force)`). The runtime returns the force or `null`/`undefined`.
  d3Force: ((name: string) =>
    | {
        strength?: (v: number) => unknown;
        distance?: (v: number) => unknown;
        radius?: (v: number) => unknown;
      }
    | undefined) &
    ((name: string, force: unknown) => unknown);
  d3ReheatSimulation?: () => void;
  zoomToFit?: (
    transitionDuration?: number,
    padding?: number,
    nodeFilter?: (node: unknown) => boolean,
  ) => void;
  centerAt?: (x?: number, y?: number, transitionDuration?: number) => void;
  // Reading (no args) returns the current zoom level; setting passes (zoom, duration).
  zoom?: (zoom?: number, transitionDuration?: number) => unknown;
  // Pixel-space deltas used while dragging the minimap viewport indicator.
  screen2GraphCoords?: (x: number, y: number) => { x: number; y: number };
  graph2ScreenCoords?: (x: number, y: number) => { x: number; y: number };
};

// zoomToFit on a sparse graph (especially a single node) over-magnifies — the
// API tries to fill the canvas with whatever's there, so a lone node ends up
// rendered as a giant ball. After fitting, cap the zoom so small graphs stay
// at a sensible scale; large graphs are unaffected because their natural fit
// zoom is already below the cap.
function fitWithMaxZoom(
  fg: ForceGraphHandle | null,
  duration: number,
  padding: number,
  maxZoom = 3,
) {
  if (!fg) return;
  fg.zoomToFit?.(duration, padding);
  window.setTimeout(() => {
    const current = fg.zoom?.();
    if (typeof current === "number" && current > maxZoom) {
      fg.zoom?.(maxZoom, 250);
    }
  }, duration + 30);
}

export interface GraphViewHandle {
  focusEntity: (id: string) => void;
  /** Smoothly recenter the camera on a graph-coord position. Used by the minimap drag. */
  panTo: (graphX: number, graphY: number, durationMs?: number) => void;
}

export const GraphView = forwardRef<GraphViewHandle, Props>(function GraphView(
  {
    entities,
    relations,
    highlightId,
    activeEntityIds = [],
    activeRelationIds = [],
    onSelect,
    onLayoutChange,
    onViewportChange,
    className,
  },
  ref,
) {
  const [Comp, setComp] = useState<ComponentType<ForceGraphProps> | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const fgRef = useRef<ForceGraphHandle | null>(null);
  const [size, setSize] = useState({ w: 600, h: 480 });
  // Card background color, read from the actual container so icon cutouts
  // stay invisible against the canvas in both light and dark themes.
  const [cardBg, setCardBg] = useState("#fbf7ec");
  const activeEntitySet = useMemo(() => new Set(activeEntityIds), [activeEntityIds]);
  const activeRelationSet = useMemo(() => new Set(activeRelationIds), [activeRelationIds]);

  useEffect(() => {
    if (!containerRef.current) return;
    const update = () => {
      if (!containerRef.current) return;
      const bg = getComputedStyle(containerRef.current).backgroundColor;
      if (bg) setCardBg(bg);
    };
    update();
    const mo = new MutationObserver(update);
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => mo.disconnect();
  }, []);

  useEffect(() => {
    let mounted = true;
    // Browser-only: react-force-graph-2d depends on canvas/DOM and cannot be bundled for SSR.
    import(/* @vite-ignore */ "react-force-graph-2d" as string).then((module: unknown) => {
      const forceGraphModule = module as { default: ComponentType<ForceGraphProps> };
      if (mounted) setComp(() => forceGraphModule.default);
    });
    return () => {
      mounted = false;
    };
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

  // Stronger repulsion + collision so nodes don't overlap and the layout is
  // legible at a glance. d3-force defaults are too gentle for label-heavy
  // canvases — we want labels readable, not stacked.
  //
  // forceX/forceY at zero with a small strength acts as a soft gravity well:
  // disconnected components — which the link force can't pull together —
  // drift toward the center instead of marching off to infinity. Strength is
  // light enough that well-connected clusters still spread naturally.
  useEffect(() => {
    if (!Comp) return;
    const fg = fgRef.current;
    if (!fg || typeof fg.d3Force !== "function") return;
    fg.d3Force("charge")?.strength?.(-260);
    fg.d3Force("link")?.distance?.(70);
    fg.d3Force("collide")?.radius?.(22);
    fg.d3Force("x", forceX(0).strength(0.06));
    fg.d3Force("y", forceY(0).strength(0.06));
    fg.d3ReheatSimulation?.();
  }, [Comp, entities.length]);

  // Re-frame on container size changes (e.g. sidebar collapse/expand). The
  // padding transition runs ~500ms, so debounce a single zoomToFit to fire
  // after the resize settles — otherwise we'd thrash the camera on every
  // ResizeObserver tick during the animation. Final fit covers the canvas
  // with a 600ms transition, syncing visually with the layout shift.
  useEffect(() => {
    if (!Comp) return;
    const t = setTimeout(() => {
      fitWithMaxZoom(fgRef.current, 600, 60);
    }, 120);
    return () => clearTimeout(t);
  }, [Comp, size.w, size.h]);

  const data = useMemo(
    () => ({
      nodes: entities.map((e) => ({
        id: e.id,
        name: e.name,
        type: e.type,
        val: 1 + Math.log2(1 + e.mentions) * 3,
        color: TYPE_COLORS[e.type] ?? TYPE_COLORS.other,
      })),
      links: relations
        .filter(
          (r) =>
            !r.supersededAt &&
            entities.find((e) => e.id === r.source) &&
            entities.find((e) => e.id === r.target),
        )
        .map((r) => ({ id: r.id, source: r.source, target: r.target, label: r.label })),
    }),
    [entities, relations],
  );

  // Imperative handle for external pan-to-node calls (used by GraphMinimap so
  // clicking a minimap node smoothly recenters the main canvas on it). Kept
  // off the onSelect path so main-graph node clicks don't auto-pan, which
  // would feel disorienting (the clicked node is already in view).
  useImperativeHandle(
    ref,
    () => ({
      focusEntity: (id: string) => {
        const node = (data.nodes as ForceGraphNode[]).find((n) => n.id === id);
        if (node?.x != null && node?.y != null) {
          fgRef.current?.centerAt?.(node.x, node.y, 600);
        }
      },
      panTo: (graphX: number, graphY: number, durationMs = 0) => {
        fgRef.current?.centerAt?.(graphX, graphY, durationMs);
      },
    }),
    [data],
  );

  // Layout snapshots: walk `data.nodes` (whose .x/.y are mutated in place by
  // the simulation) and emit a {positions, bounds} record. Throttled to one
  // emission per animation frame so the minimap re-renders smoothly without
  // re-running React on every physics tick. The same helper drives both the
  // engineTick (live, while sim is hot) and engineStop (final, when cooled).
  const layoutRafRef = useRef<number | null>(null);
  const emitLayout = useCallback(() => {
    if (!onLayoutChange) return;
    if (layoutRafRef.current != null) return;
    layoutRafRef.current = requestAnimationFrame(() => {
      layoutRafRef.current = null;
      const nodes = data.nodes as ForceGraphNode[];
      if (nodes.length === 0) return;
      const positions: Record<string, { x: number; y: number }> = {};
      let minX = Infinity;
      let maxX = -Infinity;
      let minY = Infinity;
      let maxY = -Infinity;
      let count = 0;
      for (const n of nodes) {
        if (n.x == null || n.y == null) continue;
        positions[n.id] = { x: n.x, y: n.y };
        if (n.x < minX) minX = n.x;
        if (n.x > maxX) maxX = n.x;
        if (n.y < minY) minY = n.y;
        if (n.y > maxY) maxY = n.y;
        count += 1;
      }
      if (count === 0) return;
      onLayoutChange({ positions, bounds: { minX, maxX, minY, maxY } });
    });
  }, [data, onLayoutChange]);

  useEffect(() => {
    return () => {
      if (layoutRafRef.current != null) {
        cancelAnimationFrame(layoutRafRef.current);
        layoutRafRef.current = null;
      }
    };
  }, []);

  // Viewport snapshots: react-force-graph fires onZoom with the d3-zoom
  // transform {k, x, y}, but we want the graph-coord position at the canvas
  // center (so the minimap viewport rectangle has a meaningful anchor). The
  // FG handle exposes screen2GraphCoords for exactly this projection.
  const emitViewport = useCallback(() => {
    if (!onViewportChange) return;
    const fg = fgRef.current;
    if (!fg?.screen2GraphCoords || !fg.zoom) return;
    const center = fg.screen2GraphCoords(size.w / 2, size.h / 2);
    const k = fg.zoom();
    if (typeof k !== "number") return;
    onViewportChange({ cx: center.x, cy: center.y, k, w: size.w, h: size.h });
  }, [onViewportChange, size.w, size.h]);

  // Re-emit viewport when the canvas resizes (otherwise the minimap rectangle
  // stays sized for the old canvas dimensions).
  useEffect(() => {
    if (!Comp) return;
    const t = setTimeout(emitViewport, 60);
    return () => clearTimeout(t);
  }, [Comp, size.w, size.h, emitViewport]);

  return (
    <div
      ref={containerRef}
      className={cn(
        "relative h-[480px] w-full overflow-hidden rounded-lg border bg-card",
        className,
      )}
    >
      {!Comp || entities.length === 0 ? (
        entities.length === 0 ? (
          <GraphGhost />
        ) : (
          <div className="flex h-full items-center justify-center px-6">
            <span className="text-sm text-muted-foreground">Loading graph...</span>
          </div>
        )
      ) : (
        <Comp
          ref={fgRef}
          graphData={data}
          width={size.w}
          height={size.h}
          backgroundColor="transparent"
          autoPauseRedraw={false}
          nodeRelSize={5}
          linkColor={(link: unknown) =>
            activeRelationSet.has((link as ForceGraphLink).id)
              ? "rgba(192,160,64,0.78)"
              : "rgba(120,100,80,0.35)"
          }
          linkDirectionalArrowLength={4}
          linkDirectionalArrowRelPos={0.85}
          linkWidth={(link: unknown) =>
            activeRelationSet.has((link as ForceGraphLink).id) ? 2.4 : 1
          }
          linkDirectionalParticles={(link: unknown) =>
            activeRelationSet.has((link as ForceGraphLink).id) ? 3 : 0
          }
          linkDirectionalParticleWidth={2.6}
          linkDirectionalParticleSpeed={0.006}
          cooldownTicks={80}
          onEngineTick={emitLayout}
          onEngineStop={() => {
            // After the simulation cools, frame all nodes (including
            // disconnected clusters) so nothing drifts off-canvas. Without
            // this, react-force-graph leaves the camera at its initial
            // default zoom and far-flung clusters get clipped offscreen.
            // Cap zoom so a single node doesn't fill the canvas.
            fitWithMaxZoom(fgRef.current, 400, 60);
            emitLayout();
            // The fit-to-zoom triggers an onZoom internally, but the timing
            // is fragile — re-emit explicitly after the transition settles
            // so the minimap rectangle reflects the final framed view.
            window.setTimeout(emitViewport, 450);
          }}
          onZoom={emitViewport}
          onZoomEnd={emitViewport}
          onNodeClick={(node: unknown) => onSelect?.((node as ForceGraphNode).id)}
          nodeCanvasObject={(
            rawNode: unknown,
            ctx: CanvasRenderingContext2D,
            globalScale: number,
          ) => {
            const node = rawNode as ForceGraphNode;
            const x = node.x ?? 0;
            const y = node.y ?? 0;
            const label = node.name as string;
            const fontSize = 11 / Math.max(0.6, globalScale);
            const r = 4 + Math.log2(1 + (node.val ?? 1)) * 2;
            const isHi = highlightId === node.id;
            const isActive = activeEntitySet.has(node.id);
            if (isActive) {
              const pulse = (Math.sin(Date.now() / 180) + 1) / 2;
              ctx.beginPath();
              ctx.arc(x, y, r + 5 + pulse * 8, 0, Math.PI * 2, false);
              ctx.strokeStyle = `rgba(192,160,64,${0.75 - pulse * 0.45})`;
              ctx.lineWidth = Math.max(1.5, 2.5 / globalScale);
              ctx.stroke();
            }
            // Solid sphere body
            ctx.beginPath();
            ctx.arc(x, y, r, 0, Math.PI * 2);
            ctx.fillStyle = node.color;
            ctx.fill();
            // Symbol layered on top in card color; cutouts re-expose the sphere.
            // 0.62 leaves a clean color rim around the glyph at all zoom levels.
            drawNodeIcon(ctx, node.type, x, y, r * 0.62, cardBg, node.color);
            if (isHi || isActive) {
              ctx.beginPath();
              ctx.arc(x, y, r * 1.12, 0, Math.PI * 2);
              ctx.lineWidth = 1.5 / globalScale;
              ctx.strokeStyle = "#1a1208";
              ctx.stroke();
            }
            ctx.font = `${fontSize}px Inter, sans-serif`;
            ctx.fillStyle = "#1a1208";
            ctx.textAlign = "center";
            ctx.textBaseline = "top";
            ctx.fillText(label, x, y + r + 2);
          }}
        />
      )}
    </div>
  );
});

// Sidebar overview of the full graph topology. When `layout` is provided
// (the parent has wired GraphView's onLayoutChange into us), we mirror the
// main graph's positions at scaled coords — a true Figma/Sketch-style
// navigator, not a separate simulation. The viewport rectangle reflects the
// main canvas's currently-visible region and is draggable to pan it.
//
// Without `layout`, we fall back to a ghost preview (used during the brief
// window before the main graph emits its first layout, and on the empty
// home state). We dropped the legacy own-simulation rendering — having two
// independent layouts made the navigator visually disconnected from what
// the user was actually looking at.
export function GraphMinimap({
  entities,
  relations,
  className,
  height = 180,
  onSelect,
  layout,
  viewport,
  onPanTo,
}: {
  entities: Entity[];
  relations: Relation[];
  className?: string;
  height?: number;
  onSelect?: (id: string) => void;
  layout?: GraphLayoutSnapshot | null;
  viewport?: GraphViewport | null;
  /**
   * Called when the user drags the viewport rectangle or clicks empty space
   * to recenter. Receives target graph-coord position for the canvas center.
   */
  onPanTo?: (graphX: number, graphY: number) => void;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [size, setSize] = useState({ w: 200, h: height });
  const dragStateRef = useRef<{
    pointerId: number;
    startCx: number;
    startCy: number;
    startX: number;
    startY: number;
  } | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;
    const el = containerRef.current;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      setSize({ w: Math.max(120, Math.floor(r.width)), h: height });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [height]);

  // Project graph coords → minimap pixel coords. The bbox is padded by a few
  // pixels so nodes don't kiss the rounded border, and the layout is centered
  // in the available area. Scale uses the smaller of the two ratios so the
  // graph stays aspect-correct (no stretching).
  const projection = useMemo(() => {
    if (!layout) return null;
    const { bounds } = layout;
    const padding = 14;
    const usableW = Math.max(1, size.w - padding * 2);
    const usableH = Math.max(1, size.h - padding * 2);
    const graphW = Math.max(1, bounds.maxX - bounds.minX);
    const graphH = Math.max(1, bounds.maxY - bounds.minY);
    const scale = Math.min(usableW / graphW, usableH / graphH);
    const graphCx = (bounds.minX + bounds.maxX) / 2;
    const graphCy = (bounds.minY + bounds.maxY) / 2;
    const project = (gx: number, gy: number) => ({
      x: (gx - graphCx) * scale + size.w / 2,
      y: (gy - graphCy) * scale + size.h / 2,
    });
    const unproject = (px: number, py: number) => ({
      x: (px - size.w / 2) / scale + graphCx,
      y: (py - size.h / 2) / scale + graphCy,
    });
    return { scale, project, unproject };
  }, [layout, size.w, size.h]);

  // Viewport rectangle: center at the main graph's current pan center, sized
  // by canvas dimensions divided by zoom level. When the user is zoomed
  // tightly, the rectangle shrinks; zoomed out, it fills the minimap.
  const viewportRect = useMemo(() => {
    if (!projection || !viewport || viewport.k <= 0) return null;
    const center = projection.project(viewport.cx, viewport.cy);
    const w = (viewport.w / viewport.k) * projection.scale;
    const h = (viewport.h / viewport.k) * projection.scale;
    return {
      x: center.x - w / 2,
      y: center.y - h / 2,
      w,
      h,
    };
  }, [projection, viewport]);

  const handlePointerDown = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      if (!onPanTo || !projection || !viewport) return;
      // Ignore clicks on a node — those are routed via onSelect on the SVG circle.
      const target = e.target as Element;
      if (target.closest("[data-minimap-node]")) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const py = e.clientY - rect.top;
      // If the user clicked outside the viewport rectangle, jump-pan there
      // first, then start dragging — feels like grabbing the rect.
      const target_g = projection.unproject(px, py);
      onPanTo(target_g.x, target_g.y);
      e.currentTarget.setPointerCapture(e.pointerId);
      dragStateRef.current = {
        pointerId: e.pointerId,
        startCx: target_g.x,
        startCy: target_g.y,
        startX: px,
        startY: py,
      };
    },
    [onPanTo, projection, viewport],
  );

  const handlePointerMove = useCallback(
    (e: ReactPointerEvent<HTMLDivElement>) => {
      const state = dragStateRef.current;
      if (!state || state.pointerId !== e.pointerId || !onPanTo || !projection) return;
      const rect = e.currentTarget.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const py = e.clientY - rect.top;
      const dx = (px - state.startX) / projection.scale;
      const dy = (py - state.startY) / projection.scale;
      onPanTo(state.startCx + dx, state.startCy + dy);
    },
    [onPanTo, projection],
  );

  const handlePointerUp = useCallback((e: ReactPointerEvent<HTMLDivElement>) => {
    if (dragStateRef.current?.pointerId === e.pointerId) {
      dragStateRef.current = null;
      try {
        e.currentTarget.releasePointerCapture(e.pointerId);
      } catch {
        /* already released */
      }
    }
  }, []);

  const isInteractive = !!onPanTo && !!projection && !!viewport;

  return (
    <div
      ref={containerRef}
      className={cn(
        "relative w-full overflow-hidden rounded-lg border bg-background/40 select-none",
        isInteractive && "cursor-grab active:cursor-grabbing",
        className,
      )}
      style={{ height }}
      onPointerDown={isInteractive ? handlePointerDown : undefined}
      onPointerMove={isInteractive ? handlePointerMove : undefined}
      onPointerUp={isInteractive ? handlePointerUp : undefined}
      onPointerCancel={isInteractive ? handlePointerUp : undefined}
    >
      {entities.length === 0 || !layout || !projection ? (
        <div
          className="absolute inset-0 flex items-center justify-center p-3"
          style={{ opacity: entities.length === 0 ? 0.32 : 0.18 }}
        >
          <GhostConstellationSvg />
        </div>
      ) : (
        <svg width={size.w} height={size.h} className="absolute inset-0" aria-hidden="true">
          {/* Edges first so nodes paint on top */}
          <g stroke="rgba(120,100,80,0.42)" strokeWidth={0.7}>
            {relations
              .filter(
                (r) =>
                  !r.supersededAt &&
                  layout.positions[r.source] != null &&
                  layout.positions[r.target] != null,
              )
              .map((r) => {
                const a = projection.project(
                  layout.positions[r.source].x,
                  layout.positions[r.source].y,
                );
                const b = projection.project(
                  layout.positions[r.target].x,
                  layout.positions[r.target].y,
                );
                return <line key={r.id} x1={a.x} y1={a.y} x2={b.x} y2={b.y} />;
              })}
          </g>
          <g>
            {entities.map((entity) => {
              const pos = layout.positions[entity.id];
              if (!pos) return null;
              const projected = projection.project(pos.x, pos.y);
              const color = TYPE_COLORS[entity.type] ?? TYPE_COLORS.other;
              return (
                <circle
                  key={entity.id}
                  data-minimap-node="true"
                  cx={projected.x}
                  cy={projected.y}
                  r={2.6}
                  fill={color}
                  style={{ cursor: onSelect ? "pointer" : undefined }}
                  onPointerDown={(e) => {
                    // Stop bubbling so clicking a node doesn't trigger pan.
                    e.stopPropagation();
                  }}
                  onClick={onSelect ? () => onSelect(entity.id) : undefined}
                >
                  <title>{entity.name}</title>
                </circle>
              );
            })}
          </g>
          {/* Viewport indicator: rectangle showing what the main canvas sees */}
          {viewportRect && (
            <rect
              x={viewportRect.x}
              y={viewportRect.y}
              width={viewportRect.w}
              height={viewportRect.h}
              fill="oklch(from var(--amber) l c h / 0.10)"
              stroke="oklch(from var(--amber) l c h / 0.85)"
              strokeWidth={1.2}
              rx={3}
              ry={3}
              style={{ pointerEvents: "none" }}
            />
          )}
        </svg>
      )}
    </div>
  );
}

// Standalone vertical legend — render anywhere in the page chrome alongside
// the graph. Excludes the "other" bucket since it's a fallback, not a
// category users should think in.
export function GraphLegend({
  className,
  size = 18,
  itemClassName,
}: {
  className?: string;
  size?: number;
  itemClassName?: string;
}) {
  return (
    <ul
      className={cn(
        "flex flex-col gap-1.5 text-[10px] uppercase tracking-wider text-muted-foreground",
        className,
      )}
    >
      {(Object.keys(TYPE_COLORS) as EntityType[])
        .filter((t) => t !== "other")
        .map((t) => (
          <li key={t} className={cn("flex items-center gap-3", itemClassName)}>
            <NodeGlyph type={t} size={size} />
            <span>{t}</span>
          </li>
        ))}
    </ul>
  );
}

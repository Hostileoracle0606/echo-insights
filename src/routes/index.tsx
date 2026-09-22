import { createFileRoute } from "@tanstack/react-router";
import { Fragment, FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  ArrowDownLeft,
  ArrowUpRight,
  Download,
  FileText,
  Hash,
  Keyboard,
  Loader2,
  Mic,
  Network,
  Send,
  Sparkles,
  Trash2,
  Volume2,
  VolumeX,
  Waves,
  X,
} from "lucide-react";

import {
  GraphLegend,
  GraphMinimap,
  GraphView,
  type GraphLayoutSnapshot,
  type GraphViewHandle,
  type GraphViewport,
} from "@/components/graph-view";
import { useGeminiLive } from "@/hooks/use-gemini-live";
import type { GeminiFunctionDeclaration, GeminiToolCall } from "@/lib/gemini-live-client";
import {
  answerFollowUp,
  DEFAULT_EXTRACTION_MODE,
  ensureActiveNotebook,
  loadExtractionMode,
  mergeExtraction,
  saveExtractionMode,
  slugify,
  type ExtractedPayload,
} from "@/lib/journal-store";
import {
  commitNotebook,
  getNotebookSnapshot,
  newRequestId,
  type CommitOutcome,
  type NotebookChange,
} from "@/lib/notebook-commit";
import type { Entity, ExtractionMode, JournalState } from "@/lib/journal-types";
import { cn } from "@/lib/utils";
import { downloadBlob, exportToObsidianZip } from "@/lib/obsidian-export";
import type { ExtractGraphResult } from "@/lib/extract-graph";
import { createTurnMachine } from "@/lib/turn-state/reducer";
import { createTurnPipeline, type TurnPipeline } from "@/lib/turn-state/pipeline";
import { createTranscriptAssembler } from "@/lib/turn-state/transcript-assembler";
import { createLocalTurnJournal, createWebTurnPorts } from "@/lib/turn-state/web-adapter";
import type { TurnEvent, TurnMachine } from "@/lib/turn-state/types";

/**
 * Bumped whenever the extractor prompt, schema, or model changes. Recorded on
 * every finalized turn so a replayed checkpoint is never silently reinterpreted
 * by a different extractor than the one that produced it.
 */
const EXTRACTOR_VERSION = "gemini-2.5-flash/extract_graph/v2";
import { resetMemoryIndex, retrieveMemory } from "@/lib/journal-memory";
import {
  ENTITY_WORD_TARGET,
  FOCUS_BATCH_SIZE,
  GEMINI_LIVE_SYSTEM_INSTRUCTION,
} from "@/lib/conversation-policy";
import { createLiveSessionRuntime } from "@/lib/notebook-runtime-http";
import { toast, Toaster } from "sonner";
import { useSession } from "@/lib/auth/session";
import { requireAuthOrRedirect } from "@/lib/auth/require-auth";

export const Route = createFileRoute("/")({
  beforeLoad: async () => {
    await requireAuthOrRedirect();
  },
  component: Index,
});

const EMPTY_STATE: JournalState = {
  entries: [],
  entities: {},
  relations: {},
  followUps: [],
  askedQuestions: [],
};

type ConversationTurn = {
  id: string;
  role: "user" | "agent";
  text: string;
  createdAt: string;
};

type UpsertActivity = {
  id: string;
  entityIds: string[];
  relationIds: string[];
  entityNames: string[];
  insertedEntities: number;
  updatedEntities: number;
  createdRelations: number;
  createdAt: number;
};

type GraphGap = {
  entityName: string;
  type: Entity["type"];
  reason: string;
  mentions: number;
  relationCount: number;
};

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "object" && error && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string" && message) return message;
  }
  return fallback;
}

function buildGraphGaps(state: JournalState): GraphGap[] {
  const relationCounts = new Map<string, number>();
  Object.values(state.relations).forEach((relation) => {
    relationCounts.set(relation.source, (relationCounts.get(relation.source) ?? 0) + 1);
    relationCounts.set(relation.target, (relationCounts.get(relation.target) ?? 0) + 1);
  });

  return Object.values(state.entities)
    .map((entity) => {
      const relationCount = relationCounts.get(entity.id) ?? 0;
      const reasons = [
        !entity.description ? "missing description" : "",
        relationCount === 0 ? "no relationships" : "",
        entity.mentions === 1 ? "only mentioned once" : "",
      ].filter(Boolean);

      if (reasons.length === 0) return null;

      return {
        entityName: entity.name,
        type: entity.type,
        reason: reasons.join(", "),
        mentions: entity.mentions,
        relationCount,
      };
    })
    .filter((gap): gap is GraphGap => Boolean(gap))
    .sort((a, b) => {
      if (a.relationCount !== b.relationCount) return a.relationCount - b.relationCount;
      return b.mentions - a.mentions;
    })
    .slice(0, 10);
}

function countWords(text: string): number {
  return text.trim().split(/\s+/).filter(Boolean).length;
}

function entityWordCount(state: JournalState, entityId: string): number {
  const entity = state.entities[entityId];
  if (!entity) return 0;
  let words = countWords(entity.description ?? "");
  for (const entry of state.entries) {
    if (entry.entityIds.includes(entityId)) {
      words += countWords(entry.text);
    }
  }
  return words;
}

function coverageLabel(words: number): "thin" | "developing" | "rich" {
  if (words >= ENTITY_WORD_TARGET) return "rich";
  if (words >= ENTITY_WORD_TARGET / 2) return "developing";
  return "thin";
}

function buildFocusBatch(state: JournalState) {
  // Skip entities that already have an unanswered follow-up so we don't double-prompt.
  const pendingEntityIds = new Set(
    state.followUps.filter((f) => !f.answered).flatMap((f) => f.targetEntityIds ?? []),
  );
  return Object.values(state.entities)
    .map((entity) => ({ entity, words: entityWordCount(state, entity.id) }))
    .filter(({ entity, words }) => words < ENTITY_WORD_TARGET && !pendingEntityIds.has(entity.id))
    .sort((a, b) => {
      // Thinnest first; tie-break on most recently seen so fresh threads bubble up.
      if (a.words !== b.words) return a.words - b.words;
      return b.entity.lastSeen.localeCompare(a.entity.lastSeen);
    })
    .slice(0, FOCUS_BATCH_SIZE)
    .map(({ entity, words }) => ({
      name: entity.name,
      type: entity.type,
      wordsRecorded: words,
      wordsRemaining: Math.max(0, ENTITY_WORD_TARGET - words),
      mentionCount: entity.mentions,
      description: entity.description,
      coverage: coverageLabel(words),
    }));
}

function buildBridgingCandidates(state: JournalState) {
  // Recently mentioned entities — pull from last 5 entries.
  const recentIds = new Set<string>();
  for (const entry of state.entries.slice(0, 5)) {
    for (const id of entry.entityIds) recentIds.add(id);
  }
  const recent = Array.from(recentIds)
    .map((id) => state.entities[id])
    .filter((entity): entity is Entity => Boolean(entity));
  if (recent.length < 2) return [];

  // Build edge set (undirected).
  const edges = new Set<string>();
  for (const r of Object.values(state.relations)) {
    const key = r.source < r.target ? `${r.source}|${r.target}` : `${r.target}|${r.source}`;
    edges.add(key);
  }

  const TYPE_PAIR_BONUS: Record<string, number> = {
    "person|project": 2,
    "person|event": 2,
    "person|person": 1,
    "person|place": 1,
    "place|event": 1,
    "project|event": 1,
    "person|organization": 1,
    "organization|project": 1,
  };

  const candidates: Array<{ a: Entity; b: Entity; score: number }> = [];
  for (let i = 0; i < recent.length; i += 1) {
    for (let j = i + 1; j < recent.length; j += 1) {
      const a = recent[i];
      const b = recent[j];
      const key = a.id < b.id ? `${a.id}|${b.id}` : `${b.id}|${a.id}`;
      if (edges.has(key)) continue;
      const types = [a.type, b.type].sort();
      const typeKey = `${types[0]}|${types[1]}`;
      const typeScore = TYPE_PAIR_BONUS[typeKey] ?? 0;
      const mentionScore = (a.mentions ?? 0) + (b.mentions ?? 0);
      candidates.push({ a, b, score: typeScore * 100 + mentionScore });
    }
  }

  return candidates
    .sort((x, y) => y.score - x.score)
    .slice(0, 6)
    .map(({ a, b }) => ({
      a: { name: a.name, type: a.type },
      b: { name: b.name, type: b.type },
    }));
}

/*
 * buildExtractionContext lived here. It constructed graph statistics, gaps,
 * focus entities, bridging candidates, previously-asked questions, recent
 * entries and follow-ups on every turn — and the extractor prompt read none of
 * them. What it did use was bounded by item counts ("top 20 entities"), which
 * is unbounded in tokens and blind to an older but highly relevant fact.
 *
 * Replaced by compileExtractionContext (src/lib/extraction-context.ts): the
 * finalized transcript drives semantic retrieval, and the result is packed
 * under a measured token budget.
 */

function buildUpsertActivity(
  prev: JournalState,
  next: JournalState,
  payload: ExtractedPayload,
): UpsertActivity | null {
  const byName = new Map<string, string>();
  Object.values(next.entities).forEach((entity) =>
    byName.set(entity.name.toLowerCase(), entity.id),
  );

  const entityIds = Array.from(
    new Set(
      (payload.entities ?? [])
        .map((entity) => byName.get(entity.name.toLowerCase()) ?? slugify(entity.name))
        .filter(Boolean),
    ),
  );

  const relationIds = Array.from(
    new Set(
      (payload.relations ?? [])
        .map((relation) => {
          const source =
            byName.get((relation.source ?? "").toLowerCase()) ?? slugify(relation.source ?? "");
          const target =
            byName.get((relation.target ?? "").toLowerCase()) ?? slugify(relation.target ?? "");
          if (!source || !target || source === target || !relation.label) return "";
          return `${source}__${relation.label}__${target}`;
        })
        .filter(Boolean),
    ),
  );

  if (entityIds.length === 0 && relationIds.length === 0) return null;

  return {
    id: `upsert-${Date.now()}`,
    entityIds,
    relationIds,
    entityNames: entityIds
      .map((id) => next.entities[id]?.name)
      .filter((name): name is string => Boolean(name)),
    insertedEntities: entityIds.filter((id) => !prev.entities[id]).length,
    updatedEntities: entityIds.filter((id) => Boolean(prev.entities[id])).length,
    createdRelations: relationIds.filter((id) => !prev.relations[id]).length,
    createdAt: Date.now(),
  };
}

function formatRelative(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.round(diffMs / 60000);
  if (diffMin < 1) return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 7) return `${diffDay}d ago`;
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function SpeakerLabel({ name, pulse }: { name: string; pulse: boolean }) {
  return (
    <span className="flex items-center gap-1.5 whitespace-nowrap text-[10px] font-medium uppercase tracking-[0.22em] text-muted-foreground">
      {pulse && (
        <span className="relative inline-flex h-1.5 w-1.5">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-75" />
          <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-accent" />
        </span>
      )}
      <span>{name}</span>
    </span>
  );
}

function Index() {
  const { user, supabase } = useSession();
  const notebookIdRef = useRef<string | null>(null);
  const [state, setState] = useState<JournalState>(EMPTY_STATE);
  const [extractionMode, setExtractionMode] = useState<ExtractionMode>(DEFAULT_EXTRACTION_MODE);
  const [hydrated, setHydrated] = useState(false);
  const [thinking, setThinking] = useState(false);
  const [highlight, setHighlight] = useState<string | null>(null);
  const [conversation, setConversation] = useState<ConversationTurn[]>([]);
  const [draft, setDraft] = useState("");
  const [liveActivity, setLiveActivity] = useState<UpsertActivity | null>(null);
  const [dockTyping, setDockTyping] = useState(false);
  const dockInputRef = useRef<HTMLInputElement | null>(null);
  // Asymmetric flank sizing with stationary mic: each side-screen sizes to
  // its own natural content, but the pill is translated by (rightCol -
  // leftCol)/2 so the mic stays glued to page-center regardless of which
  // side is larger. The left slot carries a short speaker label (~50–80px);
  // the right carries transcript text that grows word-by-word. When the
  // right slot would push the pill past dockMaxPillW, the outer flex uses
  // justify-end + overflow-hidden so the *tail* (most recent words) stays
  // visible while the head is clipped — lyrics-banner style.
  const dockLeftSlotRef = useRef<HTMLDivElement | null>(null);
  const dockRightSlotRef = useRef<HTMLDivElement | null>(null);
  const [dockLeftWidth, setDockLeftWidth] = useState(0);
  const [dockRightWidth, setDockRightWidth] = useState(0);
  // Dynamic Island vertical drawer: when the agent is speaking or the user
  // is dictating, the right slot holds only a short status label
  // ("Speaking" / "Listening") and the actual transcript drops into a
  // drawer that animates its height open below the button row. We measure
  // the drawer's natural content height (text wraps multi-line for long
  // transcripts) and animate the outer wrapper's height between 0 and that
  // measured value — CSS can't animate `auto` heights, so the JS-measured
  // pixel value is the bridge.
  const dockDrawerRef = useRef<HTMLDivElement | null>(null);
  const [dockDrawerHeight, setDockDrawerHeight] = useState(0);
  // Top-right pill drives the entity sidebar's width: they share a column,
  // and matching widths makes the right rail read as a single layout track.
  // ResizeObserver keeps them in sync as the pill grows/shrinks (count digits,
  // breakpoint changes that hide the stats span, etc.).
  const topPillRef = useRef<HTMLDivElement | null>(null);
  const [topPillWidth, setTopPillWidth] = useState<number>(360);
  // User-toggleable: when collapsed, the right rail slides off, the graph
  // canvas reclaims its width, and the bottom dock recenters & scales up
  // proportionally to fill the freed real estate.
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);

  const stateRef = useRef<JournalState>(state);
  stateRef.current = state;
  const conversationRef = useRef<ConversationTurn[]>(conversation);
  conversationRef.current = conversation;

  // Optimistic-concurrency counter from the last-known server snapshot.
  // Every commit reads this fresh (at the moment it actually runs, not when
  // it was queued) and a committed response updates it — that's what keeps
  // same-tab sequential commits from conflicting with themselves.
  const notebookRevisionRef = useRef<number>(0);
  // Serializes writes to this notebook: chaining onto this promise (instead
  // of an explicit queue array) guarantees commits reach the server in
  // submission order with exactly one in flight at a time, with no extra
  // bookkeeping. A rejection anywhere in the chain must not wedge every
  // commit queued after it, so the tail is normalized to never reject.
  const commitQueueRef = useRef<Promise<unknown>>(Promise.resolve());
  const enqueueCommit = useCallback(<T,>(task: () => Promise<T>): Promise<T> => {
    const run = commitQueueRef.current.then(task, task);
    commitQueueRef.current = run.catch(() => undefined);
    return run;
  }, []);
  // Mirrored in a ref so the turn adapter (built once) reads the
  // current mode without forcing the callback identity to change every toggle.
  const extractionModeRef = useRef<ExtractionMode>(extractionMode);
  extractionModeRef.current = extractionMode;
  const activityTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const greetedRef = useRef(false);
  // When the current voice session started; cleared on stop. Used by the
  // get_graph_summary tool to compute elapsed minutes and to scope the
  // "probed this session" set so the model doesn't re-ask within a session.
  const sessionStartRef = useRef<number | null>(null);
  // Turn processing: an explicit state machine owns finalization, identity
  // checks, durable checkpoints and commit ordering. See
  // src/lib/turn-state/ and docs/finalized-turn-extraction.md.
  const turnMachineRef = useRef<TurnMachine | null>(null);
  const turnPipelineRef = useRef<TurnPipeline | null>(null);
  const transcriptAssemblerRef = useRef(createTranscriptAssembler());
  // Imperative handle into the main GraphView so the sidebar minimap can pan
  // the canvas to a node when that node is clicked in the overview.
  const graphViewRef = useRef<GraphViewHandle | null>(null);
  // Live layout + viewport snapshots fed by GraphView, consumed by GraphMinimap
  // to render the navigator (mirrored positions + viewport rectangle).
  const [graphLayout, setGraphLayout] = useState<GraphLayoutSnapshot | null>(null);
  const [graphViewport, setGraphViewport] = useState<GraphViewport | null>(null);

  const entities = useMemo(() => Object.values(state.entities), [state.entities]);
  const relations = useMemo(() => Object.values(state.relations), [state.relations]);
  const openFollowUp = state.followUps.find((followUp) => !followUp.answered) ?? null;

  const selectedEntity = highlight ? (state.entities[highlight] ?? null) : null;

  // Selecting an entity (via graph click, minimap click, etc.) should always
  // surface its details — auto-uncollapse the sidebar so the user doesn't
  // click a node and have nothing visibly happen.
  useEffect(() => {
    if (selectedEntity) setSidebarCollapsed(false);
  }, [selectedEntity]);
  const selectedOutbound = useMemo(
    () =>
      highlight
        ? Object.values(state.relations).filter((relation) => relation.source === highlight)
        : [],
    [state.relations, highlight],
  );
  const selectedInbound = useMemo(
    () =>
      highlight
        ? Object.values(state.relations).filter((relation) => relation.target === highlight)
        : [],
    [state.relations, highlight],
  );
  const selectedEntries = useMemo(
    () =>
      highlight
        ? state.entries
            .filter((entry) => entry.entityIds.includes(highlight))
            .slice(-12)
            .reverse()
        : [],
    [state.entries, highlight],
  );

  // appendTurn was removed with the cumulative-sentence path. Conversation
  // history is no longer appended ad hoc from three call sites: the turn
  // machine owns it, and only finalized, actually-heard text ever lands there.

  const showActivity = useCallback((activity: UpsertActivity | null) => {
    if (!activity) return;
    setLiveActivity(activity);
    setHighlight(activity.entityIds[0] ?? null);
    if (activityTimerRef.current) clearTimeout(activityTimerRef.current);
    activityTimerRef.current = setTimeout(() => setLiveActivity(null), 5200);
  }, []);

  // ── Turn processing ──────────────────────────────────────────────────────
  //
  // Authority lives in the turn machine, not here. This block only supplies
  // I/O: merge-and-commit, snapshot reload, and the UI reconciliation that
  // follows a confirmed write. Everything about *when* those run — one durable
  // turn per finalized transcript, identity-checked async results, ordered
  // replay after a conflict, one reused request id per turn — is decided by
  // src/lib/turn-state/reducer.ts and carried out by its pipeline.
  const lastMergeRef = useRef<{ entryId: string; tempFollowUpId?: string } | null>(null);

  const mergeForCommit = useCallback(
    (transcript: string, payload: ExtractGraphResult) => {
      const prev = stateRef.current;
      // Branch B: Gemini owns dialogue, so the extractor's follow-up is
      // suppressed. Entities, relations AND supersedes still reach the merge —
      // contradiction detection depends on it. The cast narrows the extractor's
      // open `type: string` to the app's EntityType union, as before.
      const graphOnly = { ...payload, followUp: undefined } as ExtractedPayload;
      const merged = mergeExtraction(prev, transcript, graphOnly);
      const next = merged.next;
      stateRef.current = next;
      setState(next);
      showActivity(buildUpsertActivity(prev, next, graphOnly));
      const tempFollowUpId =
        next.followUps.length > prev.followUps.length ? next.followUps[0]?.id : undefined;
      lastMergeRef.current = { entryId: merged.entryId, tempFollowUpId };
      return { change: merged.change, entryId: merged.entryId, tempFollowUpId };
    },
    [showActivity],
  );

  if (!turnPipelineRef.current) {
    const machine = createTurnMachine({
      now: () => new Date().toISOString(),
      newTurnId: () => newRequestId(),
      newRequestId,
      extractorVersion: EXTRACTOR_VERSION,
    });
    const ports = createWebTurnPorts({
      // Every read goes through a ref so a result that resolves late sees the
      // state as it is now, not as it was when the request was issued.
      getState: () => stateRef.current,
      // Extraction consumes the turn machine's canonical role names. The
      // presentation-only "agent" label never crosses the runtime seam.
      getConversation: () =>
        turnMachineRef.current?.state.conversation.map(({ role, text }) => ({ role, text })) ?? [],
      getExtractionMode: () => extractionModeRef.current,
      getRevision: () => notebookRevisionRef.current,
      setRevision: (revision) => {
        notebookRevisionRef.current = revision;
      },
      replaceState: (next) => {
        stateRef.current = next;
        setState(next);
      },
      getAnsweringFollowUp: () => stateRef.current.followUps.find((followUp) => !followUp.answered),
      mergeForCommit,
      onCommitted: ({ entryId, tempFollowUpId, ids }) => {
        const realEntryId = ids.entryId;
        const realFollowUpId = ids.followUpId;
        if (!realEntryId && !(realFollowUpId && tempFollowUpId)) return;
        const swapped: JournalState = {
          ...stateRef.current,
          entries: realEntryId
            ? stateRef.current.entries.map((entry) =>
                entry.id === entryId ? { ...entry, id: realEntryId } : entry,
              )
            : stateRef.current.entries,
          followUps:
            realFollowUpId && tempFollowUpId
              ? stateRef.current.followUps.map((followUp) =>
                  followUp.id === tempFollowUpId ? { ...followUp, id: realFollowUpId } : followUp,
                )
              : stateRef.current.followUps,
        };
        stateRef.current = swapped;
        setState(swapped);
      },
      onError: (message) => {
        console.error("[turn-state]", message);
      },
      expireTranscriptFinalization: (speaker, generation) => {
        transcriptAssemblerRef.current.expirePending(speaker, generation);
      },
    });
    turnMachineRef.current = machine;
    turnPipelineRef.current = createTurnPipeline(machine, ports);
  }

  /** Feeds one adapter event into the machine and runs whatever it asks for. */
  const dispatchTurnEvent = useCallback((event: TurnEvent) => {
    const pipeline = turnPipelineRef.current;
    if (!pipeline) return;
    void pipeline.dispatch(event).then(() => {
      const machine = turnMachineRef.current;
      if (!machine) return;
      // "Thinking" now means "a finalized turn is still being processed",
      // not "some sentence-boundary request is in flight".
      setThinking(machine.state.pending.length > 0);
      // The machine owns canonical conversation history: it contains finalized,
      // actually-heard text only, so interrupted speech never appears.
      setConversation(
        machine.state.conversation.map((turn) => ({
          id: turn.turnId,
          role: turn.role === "assistant" ? "agent" : "user",
          text: turn.text,
          createdAt: turn.createdAt,
        })),
      );
    });
  }, []);

  // Snapshot of graph state shaped for the model's planner. Returned to the
  // model when it calls get_graph_summary. Keeping it minimal+structured
  // (rather than dumping raw entities/relations) is intentional: the model
  // uses these labels (thin / probed / justMentioned / bridgeCandidates) to
  // decide its next question without us hardcoding a state machine.
  const buildGraphSummary = useCallback(() => {
    const s = stateRef.current;
    const conv = conversationRef.current;
    const sessionStartedAt = sessionStartRef.current ?? Date.now();
    const sessionElapsedMin = Math.round(((Date.now() - sessionStartedAt) / 60000) * 10) / 10;

    const relationCounts = new Map<string, number>();
    Object.values(s.relations).forEach((relation) => {
      relationCounts.set(relation.source, (relationCounts.get(relation.source) ?? 0) + 1);
      relationCounts.set(relation.target, (relationCounts.get(relation.target) ?? 0) + 1);
    });

    const allEntities = Object.values(s.entities);
    const entitiesWithCoverage = allEntities.map((entity) => {
      const words = entityWordCount(s, entity.id);
      return {
        name: entity.name,
        type: entity.type,
        coverage: coverageLabel(words),
        mentions: entity.mentions,
        relationCount: relationCounts.get(entity.id) ?? 0,
        openQuestions: entity.questions ?? [],
      };
    });

    const thinEntities = entitiesWithCoverage
      .filter((e) => e.coverage === "thin")
      .sort((a, b) => b.mentions - a.mentions)
      .map((e) => e.name);

    // Substring match against entity names is good enough here — the model
    // uses this as a soft signal ("don't re-ask Maya, just covered her") not
    // as ground truth. Cheaper than re-running NER on the conversation log.
    const sinceSession = conv.filter(
      (turn) => new Date(turn.createdAt).getTime() >= sessionStartedAt,
    );
    const probedNames = new Set<string>();
    for (const turn of sinceSession) {
      const lower = turn.text.toLowerCase();
      for (const entity of allEntities) {
        if (lower.includes(entity.name.toLowerCase())) probedNames.add(entity.name);
      }
    }

    const lastUserTurn = [...conv].reverse().find((turn) => turn.role === "user");
    const justMentioned: string[] = [];
    if (lastUserTurn) {
      const lower = lastUserTurn.text.toLowerCase();
      for (const entity of allEntities) {
        if (lower.includes(entity.name.toLowerCase())) justMentioned.push(entity.name);
      }
    }

    const bridgeCandidates = buildBridgingCandidates(s)
      .slice(0, 6)
      .map((bridge) => [bridge.a.name, bridge.b.name] as [string, string]);

    const recentAgentQuestions = conv
      .filter((turn) => turn.role === "agent")
      .slice(-5)
      .map((turn) => turn.text);

    // Aggregated question backlog across the wiki — flat (entity, question)
    // pairs the model can sample from. Empty in granular mode (entities have
    // no questions field) so the model falls back to its default probing.
    const openQuestionsTop = allEntities
      .flatMap((entity) =>
        (entity.questions ?? []).map((question) => ({ entity: entity.name, question })),
      )
      .slice(0, 12);

    // uncertainRelations — three additive signals (each +1 if true), 0–3
    // total. Top 3 active relations with score ≥ 2 are surfaced. Used by
    // the live agent's PRESUPPOSITIONAL PROBES policy.
    //
    // Cross-turn uses ENTRY MEMBERSHIP (not entity.firstSeen) because
    // firstSeen is an ms-precision ISO timestamp that almost always
    // differs even between entities first seen in the same utterance —
    // so the inequality check would fire for nearly every relation.
    //
    // Pre-pass to keep the per-relation scoring O(1): mention counts,
    // first-containing-entry per entity, and active-pair counts.
    // s.entries is prepended on insert (newest at index 0), so iterating
    // forward and letting "last write wins" leaves firstEntryByEntity
    // pointing at the chronologically OLDEST entry that contains each
    // entity — which is what "first surfaced" means.
    const mentionCountByRelation = new Map<string, number>();
    const firstEntryByEntity = new Map<string, string>();
    for (const entry of s.entries) {
      for (const relId of entry.relationIds) {
        mentionCountByRelation.set(relId, (mentionCountByRelation.get(relId) ?? 0) + 1);
      }
      for (const entityId of entry.entityIds) {
        firstEntryByEntity.set(entityId, entry.id);
      }
    }

    const activePairCount = new Map<string, number>();
    for (const r of Object.values(s.relations)) {
      if (r.supersededAt) continue;
      const key = `${r.source}\u0000${r.target}`;
      activePairCount.set(key, (activePairCount.get(key) ?? 0) + 1);
    }

    const uncertainRelations = Object.values(s.relations)
      .filter((r) => !r.supersededAt)
      .map((r) => {
        let score = 0;

        // Single-mention: relation appears in exactly one journal entry.
        if ((mentionCountByRelation.get(r.id) ?? 0) <= 1) score += 1;

        // Cross-turn resolution: source and target first surfaced in
        // different entries.
        const sourceEntry = firstEntryByEntity.get(r.source);
        const targetEntry = firstEntryByEntity.get(r.target);
        if (sourceEntry && targetEntry && sourceEntry !== targetEntry) score += 1;

        // First-time pair: this is the only active relation between
        // these two entities.
        if ((activePairCount.get(`${r.source}\u0000${r.target}`) ?? 0) <= 1) score += 1;

        return {
          source: s.entities[r.source]?.name,
          label: r.label,
          target: s.entities[r.target]?.name,
          score,
        };
      })
      .filter(
        (r): r is { source: string; label: string; target: string; score: number } =>
          r.score >= 2 && Boolean(r.source) && Boolean(r.target),
      )
      .sort((a, b) => b.score - a.score)
      .slice(0, 3);

    return {
      sessionElapsedMin,
      mode: extractionModeRef.current,
      entityCount: allEntities.length,
      relationCount: Object.keys(s.relations).length,
      entities: entitiesWithCoverage.sort((a, b) => b.mentions - a.mentions).slice(0, 30),
      thinEntities: thinEntities.slice(0, 10),
      probedThisSession: Array.from(probedNames).slice(0, 12),
      justMentioned,
      bridgeCandidates,
      recentAgentQuestions,
      openQuestionsTop,
      uncertainRelations,
    };
  }, []);

  // Function declarations registered with Gemini Live at setup. Memoized so
  // the underlying client doesn't see a new array on every render (which
  // would imply a session restart was needed).
  const liveTools = useMemo<GeminiFunctionDeclaration[]>(
    () => [
      {
        name: "get_graph_summary",
        description:
          "Return the current state of the user's knowledge graph: which entities exist, which are thin (need probing), which were just mentioned, bridge candidates, and uncertainRelations (the top relations the host suspects might be wrong — phrase your next question as a presupposition over one of these per the PRESUPPOSITIONAL PROBES policy). Call this BEFORE deciding your next question.",
        parameters: { type: "OBJECT", properties: {} },
      },
      {
        name: "get_relevant_memory",
        description:
          "Retrieve past memory relevant to a query from the user's knowledge graph: a focused packet of related entities, relations, and the exact things the user said (sources). Use this when the user references something from earlier or the past, or when grounding your reply in prior context would help. Distinct from get_graph_summary, which tells you what to ask next. The result is for YOUR planning only — never read it aloud.",
        parameters: {
          type: "OBJECT",
          properties: {
            query: {
              type: "STRING",
              description: "What to recall, in a few words (a name, topic, or phrase).",
            },
          },
          required: ["query"],
        },
      },
    ],
    [],
  );

  // Dispatcher for tool calls from the model. The hook handles the
  // toolResponse round-trip; we only need to return the payload (or throw,
  // which the hook converts into an error envelope).
  const handleToolCall = useCallback(
    async (call: GeminiToolCall) => {
      if (call.name === "get_graph_summary") return buildGraphSummary();
      if (call.name === "get_relevant_memory") {
        const query =
          typeof (call.args as Record<string, unknown> | undefined)?.query === "string"
            ? ((call.args as Record<string, unknown>).query as string)
            : "";
        const { context } = await retrieveMemory(
          stateRef.current,
          query,
          notebookIdRef.current ?? "active",
        );
        return { context };
      }
      return { error: `Unknown tool: ${call.name}` };
    },
    [buildGraphSummary],
  );

  const liveSessionRuntime = useMemo(() => {
    const baseUrl = import.meta.env.VITE_NOTEBOOK_RUNTIME_URL?.trim();
    if (!baseUrl) return null;
    return createLiveSessionRuntime({
      baseUrl,
      getAccessToken: async () => {
        const { data, error } = await supabase.auth.getSession();
        if (error) throw error;
        return data.session?.access_token ?? null;
      },
    });
  }, [supabase]);

  const requestLiveSession = useCallback(async () => {
    const notebookId = notebookIdRef.current;
    if (!notebookId) throw new Error("No active notebook is available");
    if (!liveSessionRuntime) {
      throw new Error("VITE_NOTEBOOK_RUNTIME_URL is missing");
    }
    return liveSessionRuntime.startLiveSession({ notebookId });
  }, [liveSessionRuntime]);

  const live = useGeminiLive({
    transcriptAssembler: transcriptAssemblerRef.current,
    startLiveSession: requestLiveSession,
    systemInstruction: GEMINI_LIVE_SYSTEM_INSTRUCTION,
    voice: "Aoede",
    silenceDurationMs: 1200,
    tools: liveTools,
    onToolCall: handleToolCall,
    // Meaningful transcript events, not cumulative sentence callbacks. The
    // machine decides which of these may become a durable turn: interim text
    // is replaceable display state, and only a finalized, immutable transcript
    // can reach the graph. Assistant turns are extracted too — they carry facts
    // the user confirmed with "yeah" — but only the portion actually heard.
    onTurnEvent: dispatchTurnEvent,
    onError: (message) => {
      toast.error(message);
    },
  });

  useEffect(() => {
    if (!user) return;
    let cancelled = false;
    (async () => {
      try {
        const notebook = await ensureActiveNotebook(user.id);
        if (cancelled) return;
        notebookIdRef.current = notebook.id;
        resetMemoryIndex();
        // One consistent read: the domain-shaped state plus the revision the
        // first commit this session must supply as expectedRevision. No more
        // refresh-time clearState -- the commit module is now the only thing
        // that clears a notebook, and only after the server confirms it.
        const snapshot = await getNotebookSnapshot(notebook.id);
        if (cancelled) return;
        const initialState = snapshot?.state ?? EMPTY_STATE;
        notebookRevisionRef.current = snapshot?.revision ?? 0;
        setState(initialState);
        stateRef.current = initialState;
        setExtractionMode(loadExtractionMode());
        setHydrated(true);

        // Crash recovery. Anything still in the turn journal is a finalized
        // transcript whose durable processing did not finish: the process
        // stopped after recording it, after extracting from it, or after
        // sending a commit whose response never arrived. Each resumes from its
        // own last completed stage — a stored extraction is reused instead of
        // paying the model again, and a pending commit is retried with the
        // request id it already used, which the server ledger deduplicates.
        const machine = turnMachineRef.current;
        const pipeline = turnPipelineRef.current;
        if (machine && pipeline) {
          await pipeline.dispatch({
            type: "sessionStarted",
            sessionId: `restore-${notebook.id}`,
            notebookId: notebook.id,
          });
          await pipeline.dispatch({ type: "snapshotReloaded", revision: snapshot?.revision ?? 0 });
          const unfinished = await createLocalTurnJournal().load(notebook.id);
          if (!cancelled && unfinished.length > 0) {
            console.info(`[turn-state] resuming ${unfinished.length} unfinished turn(s)`);
            await pipeline.dispatch({ type: "restored", turns: unfinished });
          }
        }
      } catch (e) {
        console.error("Failed to initialize notebook:", e);
        // Fallback to empty state so the UI still renders
        setHydrated(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [user]);

  // No more "save on every state change": each mutation now commits itself
  // explicitly at its own call site (the turn pipeline, skipFollowUp,
  // handleClear), each with its own requestId and revision check.

  useEffect(() => {
    const el = topPillRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setTopPillWidth(Math.round(el.getBoundingClientRect().width));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Each dock slot is wrapped in an inline-flex whitespace-nowrap div, so
  // its box width tracks the content's natural unwrapped size. ResizeObserver
  // fires whenever a transcript word arrives, the form input grows, etc. We
  // record left and right independently so each grid track sizes to its own
  // content. Functional setState with an equality bail prevents redundant
  // re-renders when the measured value is unchanged.
  useEffect(() => {
    const l = dockLeftSlotRef.current;
    const r = dockRightSlotRef.current;
    if (!l || !r) return;
    const measure = () => {
      const lw = l.scrollWidth;
      const rw = r.scrollWidth;
      setDockLeftWidth((prev) => (prev === lw ? prev : lw));
      setDockRightWidth((prev) => (prev === rw ? prev : rw));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(l);
    ro.observe(r);
    return () => ro.disconnect();
  }, []);

  // Drawer height tracker: re-measures whenever transcript text wraps to a
  // new line or content swaps (user → agent transcript on turn change).
  // offsetHeight beats getBoundingClientRect here because we want the
  // post-layout integer pixel height, not a fractional value that may
  // produce sub-pixel jitter during the height transition.
  useEffect(() => {
    const el = dockDrawerRef.current;
    if (!el) return;
    const measure = () => {
      const next = el.offsetHeight;
      setDockDrawerHeight((prev) => (prev === next ? prev : next));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    if (hydrated) saveExtractionMode(extractionMode);
  }, [extractionMode, hydrated]);

  // Greeting kick: once Gemini Live is connected, send a single text primer
  // so the model begins the session. The primer is intentionally minimal —
  // the system prompt instructs the model to call get_graph_summary before
  // its opening line, so we don't inject entity context here. The primer
  // exists only because gemini-3.1-flash-live-preview won't speak until it
  // receives some user input (audio or realtimeInput.text).
  useEffect(() => {
    if (!hydrated || !live.ready || greetedRef.current) return;
    greetedRef.current = true;
    sessionStartRef.current = Date.now();
    // A new socket gets a new session identity. On the SAME notebook this only
    // clears in-progress, replaceable turns — finalized turns still waiting to
    // commit are notebook-scoped and survive the reconnect.
    const notebookId = notebookIdRef.current;
    if (notebookId) {
      dispatchTurnEvent({
        type: "sessionStarted",
        sessionId: `live-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        notebookId,
      });
    }
    live.sendText(
      "(Session started. Follow your SESSION OPENING instructions and greet the user.)",
    );
  }, [hydrated, live, dispatchTurnEvent]);

  useEffect(() => {
    return () => {
      if (activityTimerRef.current) clearTimeout(activityTimerRef.current);
    };
  }, []);

  useEffect(() => {
    if (dockTyping) dockInputRef.current?.focus();
  }, [dockTyping]);

  useEffect(() => {
    function handleKey(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      if (dockTyping) setDockTyping(false);
      else if (live.speaking) live.interruptAgent();
    }
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [dockTyping, live]);

  async function toggleListening() {
    if (live.listening) {
      live.stop();
      greetedRef.current = false;
      sessionStartRef.current = null;
    } else {
      setDockTyping(false);
      await live.start();
    }
  }

  function toggleDockTyping() {
    setDockTyping((current) => !current);
  }

  function handleDockSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const text = draft.trim();
    if (!text) return;
    setDraft("");
    setDockTyping(false);
    if (live.ready) live.sendText(text);
    // A typed turn is already final and immutable — it goes straight to the
    // finalized path with no interim stage.
    dispatchTurnEvent({ type: "finalTranscript", speaker: "user", text });
    dispatchTurnEvent({ type: "turnCompleted", speaker: "user" });
  }

  function skipFollowUp(followUpId: string) {
    const next = answerFollowUp(stateRef.current, followUpId);
    stateRef.current = next;
    setState(next);
    const nbId = notebookIdRef.current;
    if (!nbId) return;
    enqueueCommit(async () => {
      const attempt = async (expectedRevision: number): Promise<CommitOutcome | null> => {
        try {
          return await commitNotebook({
            notebookId: nbId,
            expectedRevision,
            requestId: newRequestId(),
            change: { kind: "answerFollowUp", followUpId },
          });
        } catch (e) {
          console.error("skipFollowUp: RPC threw", e);
          return null;
        }
      };
      let outcome = await attempt(notebookRevisionRef.current);
      if (outcome?.status === "conflict") {
        // Fixed-target change (no re-merge needed) -- just retry once
        // against the revision the conflict reported.
        notebookRevisionRef.current = outcome.currentRevision;
        outcome = await attempt(outcome.currentRevision);
      }
      if (outcome?.status === "committed") {
        notebookRevisionRef.current = outcome.revision;
      } else if (outcome?.status === "rejected") {
        console.error("skipFollowUp rejected:", outcome.code);
      }
    });
  }

  async function handleExport() {
    if (entities.length === 0) {
      toast.error("Nothing to export yet.");
      return;
    }
    try {
      const blob = await exportToObsidianZip(state);
      downloadBlob(blob, `lumen-vault-${new Date().toISOString().slice(0, 10)}.zip`);
      toast.success("Vault exported.");
    } catch (e) {
      console.error(e);
      toast.error("Export failed.");
    }
  }

  async function handleClear() {
    if (!confirm("Erase your journal, graph, and follow-ups? This cannot be undone.")) return;
    const nbId = notebookIdRef.current;
    if (!nbId) return;
    // Commit-first, not optimistic-first: a destructive change only ever
    // shows as "cleared" once the server confirms it, and a conflict never
    // auto-retries -- reload what's actually there and make the person
    // confirm again rather than silently erase newer data from elsewhere.
    const outcome = await enqueueCommit(() =>
      commitNotebook({
        notebookId: nbId,
        expectedRevision: notebookRevisionRef.current,
        requestId: newRequestId(),
        change: { kind: "clearNotebook" },
      }).catch((e) => {
        console.error("handleClear: commit threw", e);
        return null;
      }),
    );

    if (outcome?.status !== "committed") {
      const fresh = await getNotebookSnapshot(nbId).catch(() => null);
      if (fresh) {
        notebookRevisionRef.current = fresh.revision;
        setState(fresh.state);
        stateRef.current = fresh.state;
      }
      toast.error("Couldn't clear the journal -- please try again.");
      return;
    }

    notebookRevisionRef.current = outcome.revision;
    setState(EMPTY_STATE);
    stateRef.current = EMPTY_STATE;
    resetMemoryIndex();
    setConversation([]);
    setLiveActivity(null);
    setHighlight(null);
    live.stop();
    greetedRef.current = false;
    sessionStartRef.current = null;
    toast.success("Journal cleared.");
  }

  const liveEntityIds = liveActivity?.entityIds ?? [];
  const liveRelationIds = liveActivity?.relationIds ?? [];
  // Mercury silhouette engages whenever audio is flowing in either direction.
  const voiceActive = live.listening || live.speaking;
  // Dynamic Island morph: pill expands when there's content to show. Idle =
  // collapsed narrow pill, just buttons. We treat agentTranscript-with-content
  // as expanded so the pill stays open after the agent stops speaking but the
  // text is still on screen (otherwise the user sees a single jarring snap to
  // collapsed before the next state takes over).
  const isExpanded =
    dockTyping ||
    live.listening ||
    live.speaking ||
    Boolean(live.agentTranscript) ||
    thinking ||
    Boolean(openFollowUp);

  // Pill geometry: each flank gets its own column sized to its natural
  // content. Cluster = 12px outer padding + 44+48+44 button row = 148px.
  // Each flank's inner padding sums to 20px (pl-2+pr-3 / pl-3+pr-2). When
  // natural content sums below the pill's minimum, the deficit splits
  // equally between the two flanks (preserving the right-vs-left difference,
  // so the shift formula is identical in both modes). When total content
  // exceeds dockMaxPillW, the left slot (short speaker label) gets its
  // natural width first; the right slot (transcript) absorbs the remainder
  // and clips its head via justify-end + overflow-hidden, keeping the
  // latest words visible. Mic-pinning shift: dockPillShift translates the
  // pill so the mic — which sits clusterW/2 from the pill's geometric
  // center — lands back on page-center regardless of flank asymmetry.
  // Drawer is open whenever there's transcript content to show during
  // speaking or listening. We don't open it for thinking/follow-up — those
  // already fit a single short line in the right slot. Typing always wins:
  // when the user is composing, the right-slot form gets the focus and the
  // drawer stays closed.
  const dockDrawerOpen =
    !dockTyping &&
    ((live.speaking && Boolean(live.agentTranscript)) ||
      (live.listening && Boolean(live.userTranscript)));
  // When the drawer is open, give the pill a comfortable reading width so
  // the transcript doesn't wrap into a thin column. Otherwise keep the
  // compact min so idle/thinking/typing modes stay snug.
  const dockMinPillW = dockDrawerOpen
    ? sidebarCollapsed
      ? 380
      : 340
    : sidebarCollapsed
      ? 220
      : 180;
  const dockMaxPillW = sidebarCollapsed ? 720 : 560;
  const dockClusterW = 148;
  const dockFlankPad = 20;
  const dockLeftNatural = isExpanded && dockLeftWidth > 0 ? dockLeftWidth + dockFlankPad : 0;
  const dockRightNatural = isExpanded && dockRightWidth > 0 ? dockRightWidth + dockFlankPad : 0;
  const dockMaxFlanks = Math.max(0, dockMaxPillW - dockClusterW);
  const dockMinFlanks = Math.max(0, dockMinPillW - dockClusterW);
  const dockNaturalSum = dockLeftNatural + dockRightNatural;
  const dockMinPad = dockNaturalSum < dockMinFlanks ? (dockMinFlanks - dockNaturalSum) / 2 : 0;
  let dockLeftCol = dockLeftNatural + dockMinPad;
  let dockRightCol = dockRightNatural + dockMinPad;
  const dockOverflow = dockLeftCol + dockRightCol - dockMaxFlanks;
  if (dockOverflow > 0) {
    const rightTrim = Math.min(dockRightCol, dockOverflow);
    dockRightCol -= rightTrim;
    const remaining = dockOverflow - rightTrim;
    if (remaining > 0) dockLeftCol = Math.max(0, dockLeftCol - remaining);
  }
  const dockPillW = dockClusterW + dockLeftCol + dockRightCol;
  const dockPillShift = (dockRightCol - dockLeftCol) / 2;

  return (
    <div className="min-h-screen bg-background text-foreground">
      <Toaster richColors position="top-center" />
      {/* Goo filter shared across the layout. Defined once; referenced by
       * `filter: url(#dock-goo)` (the .goo-active class). The pipeline blurs
       * the wrapper's contents, threshold-cliffs the alpha to fuse the pill
       * and its sibling blobs into one mercury silhouette, then erodes +
       * subtracts to draw a 1px --color-border outline along the bumpy edge
       * — same border weight/color as the static pill. See styles.css. */}
      <svg aria-hidden width="0" height="0" style={{ position: "absolute" }}>
        <defs>
          <filter id="dock-goo">
            <feGaussianBlur in="SourceGraphic" stdDeviation="6" result="blur" />
            <feColorMatrix
              in="blur"
              mode="matrix"
              values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 18 -7"
              result="goo"
            />
            <feMorphology in="goo" operator="erode" radius="1" result="eroded" />
            <feComposite in="goo" in2="eroded" operator="out" result="ring" />
            <feFlood style={{ floodColor: "var(--color-border)" }} result="bordercolor" />
            <feComposite in="bordercolor" in2="ring" operator="in" result="coloredOutline" />
            <feMerge>
              <feMergeNode in="goo" />
              <feMergeNode in="coloredOutline" />
            </feMerge>
          </filter>
        </defs>
      </svg>
      <main className="relative min-h-screen">
        <section
          className="relative flex min-h-[62vh] flex-col overflow-hidden border-b bg-background lg:min-h-screen lg:border-b-0 lg:pr-[var(--sidebar-reserve,0px)] lg:transition-[padding] lg:duration-500 lg:ease-[cubic-bezier(0.32,0.72,0,1)]"
          style={
            {
              // Graph re-centers in the visible (non-sidebar) region by
              // reserving right-side padding equal to the fixed sidebar's
              // footprint plus a 48px gap (24px right offset + 24px breathing
              // room from the graph). When the sidebar is collapsed the
              // reserve drops to 0 and the graph reclaims the full width;
              // the padding transition above smoothly animates that shift.
              "--sidebar-reserve": sidebarCollapsed ? "0px" : `${topPillWidth + 48}px`,
            } as React.CSSProperties
          }
        >
          <div className="pointer-events-none absolute inset-x-0 top-0 z-10 flex items-start justify-between gap-4 bg-gradient-to-b from-background/90 to-transparent px-4 py-4 sm:px-6">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-foreground text-background shadow-[var(--shadow-paper)]">
                <Sparkles className="h-4 w-4" />
              </div>
              <div>
                <h1 className="font-display text-xl leading-none">Lumen</h1>
                <p className="mt-1 text-xs text-muted-foreground">Voice journal knowledge graph</p>
              </div>
            </div>
            <div
              ref={topPillRef}
              className="pointer-events-auto flex items-center gap-1 rounded-full border bg-card/95 p-1 shadow-[var(--shadow-paper)] backdrop-blur"
            >
              <button
                type="button"
                onClick={() => setSidebarCollapsed((c) => !c)}
                aria-pressed={!sidebarCollapsed}
                aria-label={sidebarCollapsed ? "Show sidebar" : "Hide sidebar"}
                title={sidebarCollapsed ? "Show sidebar" : "Hide sidebar"}
                className={cn(
                  "hidden items-center gap-1.5 rounded-full px-2 py-1 text-xs text-muted-foreground transition sm:flex",
                  "hover:bg-background hover:text-foreground",
                  sidebarCollapsed && "bg-background/60 text-foreground",
                )}
              >
                <Network className="h-3.5 w-3.5" />
                <span className="text-foreground">{entities.length}</span>
                <span>·</span>
                <span>{relations.length} links</span>
              </button>
              <div
                role="group"
                aria-label="Extraction mode"
                className="hidden items-center gap-0.5 rounded-full bg-background/60 p-0.5 sm:flex"
              >
                <button
                  type="button"
                  onClick={() => setExtractionMode("wiki")}
                  aria-pressed={extractionMode === "wiki"}
                  title="Wiki mode — only nodes that can anchor a line of questioning"
                  className={cn(
                    "rounded-full px-2.5 py-1 text-[11px] font-medium transition",
                    extractionMode === "wiki"
                      ? "bg-foreground text-background"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  Wiki
                </button>
                <button
                  type="button"
                  onClick={() => setExtractionMode("granular")}
                  aria-pressed={extractionMode === "granular"}
                  title="Granular mode — every named entity becomes a node"
                  className={cn(
                    "rounded-full px-2.5 py-1 text-[11px] font-medium transition",
                    extractionMode === "granular"
                      ? "bg-foreground text-background"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  Granular
                </button>
              </div>
              <button
                type="button"
                onClick={handleExport}
                title="Export to Obsidian"
                aria-label="Export to Obsidian"
                className="inline-flex h-9 w-9 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground"
              >
                <Download className="h-4 w-4" />
              </button>
              <button
                type="button"
                onClick={handleClear}
                title="Clear journal"
                aria-label="Clear journal"
                className="inline-flex h-9 w-9 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-destructive"
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
          </div>

          <GraphView
            ref={graphViewRef}
            entities={entities}
            relations={relations}
            highlightId={highlight}
            activeEntityIds={liveEntityIds}
            activeRelationIds={liveRelationIds}
            onSelect={setHighlight}
            onLayoutChange={setGraphLayout}
            onViewportChange={setGraphViewport}
            className="h-[62vh] min-h-[460px] rounded-none border-0 bg-transparent lg:h-screen"
          />

          <div className="pointer-events-none absolute bottom-6 left-0 right-0 z-20 flex flex-col items-center gap-2 px-4 lg:right-[var(--sidebar-reserve,0px)] lg:transition-[right] lg:duration-500 lg:ease-[cubic-bezier(0.32,0.72,0,1)]">
            {hydrated && !live.supported && (
              <div className="pointer-events-auto inline-flex items-center gap-2 rounded-full border border-destructive/30 bg-destructive/5 px-3 py-1.5 text-xs text-destructive shadow-[var(--shadow-paper)] backdrop-blur">
                <AlertCircle className="h-3.5 w-3.5" />
                <span>Voice unavailable here — typing still works.</span>
              </div>
            )}
            {live.error && (
              <div className="pointer-events-auto max-w-[480px] rounded-full border border-destructive/30 bg-destructive/10 px-3 py-1.5 text-xs text-destructive shadow-[var(--shadow-paper)] backdrop-blur">
                {live.error}
                {live.permissionState === "denied" &&
                  " Re-enable mic access in site controls and reload."}
              </div>
            )}
            {liveActivity && (
              <div
                key={liveActivity.id}
                className="upsert-pop pointer-events-auto flex max-w-[min(560px,calc(100%-2rem))] flex-wrap items-center justify-center gap-2 rounded-full border bg-card/90 px-4 py-2 shadow-[var(--shadow-paper)] backdrop-blur"
              >
                <Waves className="h-3.5 w-3.5 shrink-0 text-accent" />
                <span className="text-[11px] font-medium uppercase tracking-[0.14em] text-muted-foreground">
                  Upserting
                </span>
                <div className="flex flex-wrap items-center gap-1.5">
                  {liveActivity.entityNames.slice(0, 4).map((name) => (
                    <span
                      key={name}
                      className="rounded-full border bg-background px-2 py-0.5 text-[11px] font-medium"
                    >
                      {name}
                    </span>
                  ))}
                  {liveActivity.entityNames.length > 4 && (
                    <span className="rounded-full border bg-background px-2 py-0.5 text-[11px] text-muted-foreground">
                      +{liveActivity.entityNames.length - 4}
                    </span>
                  )}
                </div>
                <span className="text-[11px] text-muted-foreground">
                  {liveActivity.insertedEntities} new · {liveActivity.updatedEntities} refreshed ·{" "}
                  {liveActivity.createdRelations} links
                </span>
              </div>
            )}
            {/* Dynamic Island morphing capsule + mercury silhouette.
             *
             * Two stacked layers inside one wrapper:
             *  - silhouette layer (voice modes only): absolute inset-0, holds
             *    the .goo-active filter, a card-colored rect, and the blob
             *    spans. The goo filter scope is CONTAINED here so it blurs
             *    only silhouette pixels — never the transcript text or icons.
             *  - content layer: relative, in flow, drives the parent's size
             *    via the grid morph. Holds the actual transcript + buttons.
             *    No filter, so text stays crisp.
             *
             * Both layers share the parent's bounds: content drives the
             * morph (width: 180→560, grid-rows: 0fr→1fr), silhouette tracks
             * via inset-0. Result: the mercury pill resizes lockstep with
             * the morph without any duplicated animation wiring.
             *
             * Border + shadow come off the content layer in voice modes —
             * the silhouette behind provides the visible bg, and the goo
             * filter's outline pass adds the 1px --color-border stroke on
             * the rippled edge. */}
            {/* Mic-pinning shift lives on the wrapper, not the pill content,
             * so BOTH the goo silhouette layer (absolute inset-0 inside the
             * wrapper) and the in-flow pill content shift together. If the
             * transform sat on the pill content alone, the silhouette
             * (which gets its bounds from the wrapper) would stay put while
             * the pill drifted off it — the goo blobs would float
             * disconnected from the pill outline. */}
            <div
              className="pointer-events-auto relative transition-transform duration-300 ease-[cubic-bezier(0.32,0.72,0,1)]"
              style={{ transform: `translateX(${dockPillShift}px)` }}
            >
              {voiceActive && (
                <div aria-hidden className="goo-active pointer-events-none absolute inset-0">
                  <div className="absolute inset-0 rounded-[32px] bg-card" />
                  <span className="goo-blob goo-blob-t1" />
                  <span className="goo-blob goo-blob-t2" />
                  <span className="goo-blob goo-blob-b1" />
                  <span className="goo-blob goo-blob-b2" />
                </div>
              )}
              <div
                aria-live="polite"
                className={cn(
                  // rounded-[32px] (not rounded-full): keeps a near-pill
                  // shape when collapsed at ~60px height (corner radius =
                  // half of height ≈ 30px so the difference is invisible),
                  // and gives a clean rounded-rectangle when expanded —
                  // instead of the corner radius ballooning to 65px+ on a
                  // tall pill, which would carve into the drawer text.
                  "relative flex flex-col overflow-hidden rounded-[32px]",
                  // Width animates on this column container (asymmetric
                  // flank changes); the inner grid row inherits the width
                  // automatically. Drawer height animates on the inner
                  // drawer wrapper. The wrapper transform shifts both
                  // layers in lockstep so the mic stays glued to
                  // page-center regardless of flank asymmetry.
                  "transition-[width] duration-300 ease-[cubic-bezier(0.32,0.72,0,1)]",
                  voiceActive ? "" : "border bg-card/95 shadow-[var(--shadow-paper)]",
                )}
                style={{
                  width: `${dockPillW}px`,
                  maxWidth: `min(${dockMaxPillW}px, calc(100vw - 2rem))`,
                }}
              >
                {/* Drawer: holds the transcript when the agent is speaking
                 * or the user is dictating. Sits ABOVE the button row, so
                 * the pill's bottom edge stays anchored to the dock parent
                 * (which itself is bottom-anchored at `bottom-6`) and the
                 * drawer's growth pushes the pill's top edge upward —
                 * Dynamic Island morphs UPWARD from the bottom. The outer
                 * wrapper animates its height between 0 (closed) and the
                 * measured content height (open); the inner div is what
                 * ResizeObserver watches.
                 *
                 * Padding rationale: pt-5 keeps text clear of the
                 * rounded-[32px] top corners; px-6 gives generous side
                 * margins so the lyrics don't kiss the edge; pb-1 is
                 * tight because the bottom of the drawer abuts the button
                 * row's own py-1.5 padding. */}
                <div
                  className="overflow-hidden transition-[height] duration-300 ease-[cubic-bezier(0.32,0.72,0,1)]"
                  style={{ height: dockDrawerOpen ? `${dockDrawerHeight}px` : "0px" }}
                  aria-hidden={!dockDrawerOpen}
                >
                  <div ref={dockDrawerRef} className="px-6 pt-5 pb-1">
                    {live.speaking ? (
                      <p className="line-clamp-4 text-sm leading-relaxed text-foreground">
                        {live.agentTranscript || "…"}
                      </p>
                    ) : live.listening ? (
                      <p className="line-clamp-4 text-sm leading-relaxed text-foreground">
                        {live.userTranscript || "…"}
                      </p>
                    ) : null}
                  </div>
                </div>
                {/* Top row: 5-track button bar.
                 * [left-flank] [keyboard] [mic] [speaker] [right-flank].
                 * Each flank track is sized to its own measured content
                 * width via inline gridTemplateColumns. */}
                <div
                  className="grid items-center px-1.5 py-1.5 transition-[grid-template-columns] duration-300 ease-[cubic-bezier(0.32,0.72,0,1)]"
                  style={{
                    gridTemplateColumns: `minmax(0, ${dockLeftCol}px) auto auto auto minmax(0, ${dockRightCol}px)`,
                  }}
                >
                  {/* Track 1: left screen — extends outward from keyboard's left edge */}
                  <div
                    className={cn(
                      "flex h-full min-w-0 items-center justify-end overflow-hidden pr-3 pl-2 transition-opacity",
                      isExpanded
                        ? "opacity-100 duration-300 delay-200"
                        : "opacity-0 duration-100 delay-0",
                    )}
                  >
                    <div
                      ref={dockLeftSlotRef}
                      className="inline-flex items-center whitespace-nowrap"
                    >
                      {dockTyping ? null : live.speaking || live.agentTranscript ? (
                        <SpeakerLabel name="Lumen" pulse={live.speaking} />
                      ) : live.listening ? (
                        <SpeakerLabel name="You" pulse={true} />
                      ) : thinking ? (
                        <SpeakerLabel name="Mapping" pulse={false} />
                      ) : openFollowUp ? (
                        <SpeakerLabel name="Lumen asks" pulse={false} />
                      ) : null}
                    </div>
                  </div>

                  {/* Track 2: keyboard — left of central cluster */}
                  <button
                    type="button"
                    onClick={toggleDockTyping}
                    title={dockTyping ? "Hide keyboard (Esc)" : "Type a thought"}
                    aria-label={dockTyping ? "Hide keyboard" : "Type a thought"}
                    aria-pressed={dockTyping}
                    className={cn(
                      "inline-flex h-11 w-11 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground",
                      dockTyping && "bg-background text-foreground",
                    )}
                  >
                    <Keyboard className="h-[18px] w-[18px]" />
                  </button>

                  {/* Track 3: mic — center of cluster, locked at pill midline */}
                  <button
                    type="button"
                    onClick={toggleListening}
                    disabled={!live.supported}
                    className={cn(
                      "relative inline-flex h-12 w-12 items-center justify-center rounded-full text-background transition",
                      live.listening
                        ? "bg-foreground text-accent shadow-[inset_0_1px_2px_rgba(0,0,0,0.45)] mic-pulse"
                        : "bg-foreground hover:scale-105",
                      openFollowUp &&
                        !live.listening &&
                        !dockTyping &&
                        "ring-2 ring-accent ring-offset-2 ring-offset-card",
                      !live.supported && "cursor-not-allowed opacity-45 hover:scale-100",
                    )}
                    aria-label={
                      live.listening
                        ? "Stop recording"
                        : openFollowUp
                          ? "Tap to answer Lumen"
                          : "Start recording"
                    }
                    title={
                      live.listening
                        ? "Stop recording"
                        : openFollowUp
                          ? "Tap to answer Lumen"
                          : "Start recording"
                    }
                  >
                    <Mic className="h-[18px] w-[18px]" />
                  </button>

                  {/* Track 4: speaker — right of central cluster */}
                  <button
                    type="button"
                    onClick={() => {
                      if (live.speaking) live.interruptAgent();
                      else live.setMuted(!live.muted);
                    }}
                    title={
                      live.speaking
                        ? "Stop speaking (Esc)"
                        : live.muted
                          ? "Unmute agent voice"
                          : "Mute agent voice"
                    }
                    aria-label={
                      live.speaking
                        ? "Stop speaking"
                        : live.muted
                          ? "Unmute agent voice"
                          : "Mute agent voice"
                    }
                    className={cn(
                      "inline-flex h-11 w-11 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground",
                      live.speaking && "text-accent",
                    )}
                  >
                    {!live.muted && !live.speaking ? (
                      <Volume2 className="h-[18px] w-[18px]" />
                    ) : (
                      <VolumeX className="h-[18px] w-[18px]" />
                    )}
                  </button>

                  {/* Track 5: right screen. Two roles:
                   *  - Typing mode: holds the form input (current horizontal-
                   *    expansion behavior — pill grows wider to fit the
                   *    input, no drawer involved).
                   *  - Voice modes: holds only a short status label
                   *    ("Speaking" / "Listening" / "Mapping" / "Lumen asks").
                   *    The actual transcript content moves to the drawer
                   *    below the button row, which expands the pill
                   *    vertically — Dynamic Island style. */}
                  <div
                    className={cn(
                      "flex h-full min-w-0 items-center justify-end overflow-hidden pl-3 pr-2 transition-opacity",
                      isExpanded
                        ? "opacity-100 duration-300 delay-200"
                        : "opacity-0 duration-100 delay-0",
                    )}
                  >
                    <div
                      ref={dockRightSlotRef}
                      className="inline-flex items-center whitespace-nowrap"
                    >
                      {dockTyping ? (
                        <form onSubmit={handleDockSubmit} className="flex items-center gap-2">
                          <input
                            ref={dockInputRef}
                            value={draft}
                            onChange={(event) => setDraft(event.target.value)}
                            placeholder={openFollowUp ? "Type your answer..." : "Type a thought..."}
                            className="min-w-[200px] bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground"
                          />
                          <button
                            type="submit"
                            disabled={!draft.trim() || thinking}
                            aria-label="Send"
                            className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
                          >
                            <Send className="h-3.5 w-3.5" />
                          </button>
                        </form>
                      ) : live.speaking ? (
                        <SpeakerLabel name="Speaking" pulse={true} />
                      ) : live.listening ? (
                        <SpeakerLabel
                          name={live.ready ? "Listening" : "Connecting"}
                          pulse={live.ready}
                        />
                      ) : thinking ? (
                        <SpeakerLabel name="Mapping" pulse={false} />
                      ) : openFollowUp ? (
                        <span className="flex items-center gap-2 text-[10px] font-medium uppercase tracking-[0.22em] text-muted-foreground">
                          <span>Question</span>
                          <button
                            type="button"
                            onClick={() => skipFollowUp(openFollowUp.id)}
                            title="Skip this question"
                            className="shrink-0 rounded-full px-2 py-0.5 normal-case tracking-normal transition hover:bg-background hover:text-foreground"
                          >
                            Skip
                          </button>
                        </span>
                      ) : null}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <aside
          aria-hidden={sidebarCollapsed || undefined}
          className={cn(
            "flex-col bg-card/80 lg:fixed lg:right-6 lg:top-20 lg:bottom-10 lg:z-30 lg:flex lg:w-[var(--sidebar-w)] lg:overflow-hidden lg:rounded-2xl lg:border lg:bg-card/85 lg:shadow-[var(--shadow-paper)] lg:backdrop-blur-md",
            "lg:transition-[transform,opacity] lg:duration-500 lg:ease-[cubic-bezier(0.32,0.72,0,1)]",
            sidebarCollapsed &&
              "lg:pointer-events-none lg:translate-x-[calc(100%+1.5rem)] lg:opacity-0",
            selectedEntity ? "flex" : "hidden",
          )}
          style={{ ["--sidebar-w" as string]: `${topPillWidth}px` } as React.CSSProperties}
        >
          {selectedEntity ? (
            <>
              <div className="flex items-start justify-between gap-3 border-b px-4 py-4">
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                    <Hash className="h-3 w-3" />
                    <span>{selectedEntity.type}</span>
                  </div>
                  <h2 className="mt-1 font-display text-2xl leading-tight">
                    {selectedEntity.name}
                  </h2>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {selectedEntity.mentions} mention{selectedEntity.mentions === 1 ? "" : "s"}
                    {selectedEntity.lastSeen
                      ? ` · last ${formatRelative(selectedEntity.lastSeen)}`
                      : ""}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => setHighlight(null)}
                  title="Close"
                  aria-label="Close entity viewer"
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border bg-background text-muted-foreground hover:text-foreground"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>

              <div className="flex-1 space-y-5 overflow-y-auto px-4 py-4">
                {selectedEntity.description && (
                  <p className="text-sm leading-relaxed text-foreground">
                    {selectedEntity.description}
                  </p>
                )}

                {Object.keys(selectedEntity.metadata).length > 0 && (
                  <div className="rounded-lg border bg-background/60 p-3">
                    <p className="mb-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                      Metadata
                    </p>
                    <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1.5 text-xs">
                      {Object.entries(selectedEntity.metadata).map(([key, value]) => (
                        <Fragment key={key}>
                          <dt className="text-muted-foreground">{key}</dt>
                          <dd className="break-words text-foreground">{String(value)}</dd>
                        </Fragment>
                      ))}
                    </dl>
                  </div>
                )}

                {selectedOutbound.length > 0 && (
                  <section>
                    <p className="mb-2 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                      <ArrowUpRight className="h-3 w-3" /> Outbound
                    </p>
                    <ul className="space-y-1.5">
                      {selectedOutbound.map((relation) => {
                        const target = state.entities[relation.target];
                        if (!target) return null;
                        return (
                          <li key={relation.id} className="text-sm">
                            <span className="text-muted-foreground">
                              {relation.label.replace(/_/g, " ")}
                            </span>{" "}
                            <button
                              type="button"
                              onClick={() => setHighlight(target.id)}
                              className="font-medium text-foreground underline-offset-2 hover:underline"
                            >
                              {target.name}
                            </button>
                          </li>
                        );
                      })}
                    </ul>
                  </section>
                )}

                {selectedInbound.length > 0 && (
                  <section>
                    <p className="mb-2 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                      <ArrowDownLeft className="h-3 w-3" /> Inbound
                    </p>
                    <ul className="space-y-1.5">
                      {selectedInbound.map((relation) => {
                        const source = state.entities[relation.source];
                        if (!source) return null;
                        return (
                          <li key={relation.id} className="text-sm">
                            <button
                              type="button"
                              onClick={() => setHighlight(source.id)}
                              className="font-medium text-foreground underline-offset-2 hover:underline"
                            >
                              {source.name}
                            </button>{" "}
                            <span className="text-muted-foreground">
                              {relation.label.replace(/_/g, " ")}
                            </span>
                          </li>
                        );
                      })}
                    </ul>
                  </section>
                )}

                {selectedEntries.length > 0 && (
                  <section>
                    <p className="mb-2 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                      <FileText className="h-3 w-3" /> Entries
                    </p>
                    <ul className="space-y-2">
                      {selectedEntries.map((entry) => (
                        <li
                          key={entry.id}
                          className="rounded-lg border bg-background/60 px-3 py-2 text-sm leading-relaxed"
                        >
                          <p className="text-foreground">{entry.text}</p>
                          <p className="mt-1 text-[10px] uppercase tracking-[0.14em] text-muted-foreground">
                            {formatRelative(entry.createdAt)}
                          </p>
                        </li>
                      ))}
                    </ul>
                  </section>
                )}

                {!selectedEntity.description &&
                  Object.keys(selectedEntity.metadata).length === 0 &&
                  selectedOutbound.length === 0 &&
                  selectedInbound.length === 0 &&
                  selectedEntries.length === 0 && (
                    <p className="text-sm text-muted-foreground">
                      Nothing recorded yet. Talk about {selectedEntity.name} to start filling this
                      page.
                    </p>
                  )}
              </div>
            </>
          ) : (
            <>
              <div className="flex flex-1 flex-col px-7 pt-8">
                <p className="text-[10px] font-semibold uppercase tracking-[0.22em] text-muted-foreground">
                  Lumen Notebook
                </p>
                <h2 className="mt-3 font-display text-[40px] leading-[0.95] tracking-tight">
                  Voice
                  <br />
                  Journal
                </h2>
                <p className="mt-5 max-w-[24ch] text-sm leading-relaxed text-muted-foreground">
                  A living graph of who and what you talk about.
                </p>

                <div className="pt-7">
                  <p className="mb-3 text-[10px] font-semibold uppercase tracking-[0.22em] text-muted-foreground">
                    Overview
                  </p>
                  <GraphMinimap
                    entities={entities}
                    relations={relations}
                    height={150}
                    layout={graphLayout}
                    viewport={graphViewport}
                    onPanTo={(x, y) => graphViewRef.current?.panTo(x, y)}
                    onSelect={(id) => {
                      setHighlight(id);
                      graphViewRef.current?.focusEntity(id);
                    }}
                  />
                </div>
              </div>
              <div className="border-t px-7 pb-5 pt-4">
                <p className="mb-3 text-[9px] font-semibold uppercase tracking-[0.22em] text-muted-foreground">
                  Key
                </p>
                <GraphLegend
                  size={14}
                  className="grid grid-cols-2 gap-x-4 gap-y-2 text-[10px] tracking-[0.1em]"
                  itemClassName="gap-2"
                />
              </div>
            </>
          )}
        </aside>
      </main>
    </div>
  );
}

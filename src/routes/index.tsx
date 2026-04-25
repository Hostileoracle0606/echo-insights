import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState } from "react";
import { Mic, MicOff, Network, List, Download, Sparkles, Trash2, Loader2, AlertCircle } from "lucide-react";

import { useSpeechRecognition } from "@/hooks/use-speech-recognition";
import { loadState, saveState, mergeExtraction, answerFollowUp, clearState, type ExtractedPayload } from "@/lib/journal-store";
import type { JournalState } from "@/lib/journal-types";
import { GraphView } from "@/components/graph-view";
import { EntityList } from "@/components/entity-list";
import { exportToObsidianZip, downloadBlob } from "@/lib/obsidian-export";
import { supabase } from "@/integrations/supabase/client";
import { toast, Toaster } from "sonner";

export const Route = createFileRoute("/")({ component: Index });

function Index() {
  const [state, setState] = useState<JournalState>({ entries: [], entities: {}, relations: {}, followUps: [] });
  const [hydrated, setHydrated] = useState(false);
  const [view, setView] = useState<"graph" | "list">("graph");
  const [thinking, setThinking] = useState(false);
  const [highlight, setHighlight] = useState<string | null>(null);
  const [activeFollowUpId, setActiveFollowUpId] = useState<string | null>(null);
  const speech = useSpeechRecognition();
  const transcriptRef = useRef<HTMLDivElement | null>(null);

  // hydrate from localStorage on client
  useEffect(() => {
    setState(loadState());
    setHydrated(true);
  }, []);

  // persist
  useEffect(() => { if (hydrated) saveState(state); }, [state, hydrated]);

  // auto-scroll transcript
  useEffect(() => {
    transcriptRef.current?.scrollTo({ top: transcriptRef.current.scrollHeight, behavior: "smooth" });
  }, [speech.transcript, speech.interim]);

  const entities = useMemo(() => Object.values(state.entities), [state.entities]);
  const relations = useMemo(() => Object.values(state.relations), [state.relations]);
  const openFollowUp = state.followUps.find((f) => !f.answered) ?? null;

  async function processUtterance(text: string, opts?: { followUpId?: string }) {
    if (!text.trim()) return;
    setThinking(true);
    try {
      const existing = entities.slice(0, 30).map((e) => ({ name: e.name, type: e.type, description: e.description }));
      const { data, error } = await supabase.functions.invoke("extract-graph", {
        body: { text, existingEntities: existing },
      });
      if (error) throw error;
      if ((data as any)?.error) throw new Error((data as any).error);
      const payload = data as ExtractedPayload;

      setState((prev) => {
        const merged = mergeExtraction(prev, text, payload);
        let next = merged.next;
        if (opts?.followUpId) next = answerFollowUp(next, opts.followUpId);
        return next;
      });

      const newCount = (payload.entities ?? []).length;
      if (newCount > 0) {
        toast.success(`Added ${newCount} ${newCount === 1 ? "entity" : "entities"} to your graph.`);
      }
    } catch (e: any) {
      console.error(e);
      toast.error(e?.message || "Couldn't analyze that — try again.");
    } finally {
      setThinking(false);
      setActiveFollowUpId(null);
    }
  }

  function toggleListening() {
    if (speech.listening) {
      speech.stop();
      const text = speech.transcript.trim();
      if (text) {
        processUtterance(text, { followUpId: activeFollowUpId ?? undefined });
        speech.reset();
      }
    } else {
      speech.reset();
      speech.start();
    }
  }

  function answerByVoice(followUpId: string) {
    setActiveFollowUpId(followUpId);
    if (!speech.listening) {
      speech.reset();
      speech.start();
    }
  }

  async function handleExport() {
    if (entities.length === 0) {
      toast.error("Nothing to export yet — speak first.");
      return;
    }
    try {
      const blob = await exportToObsidianZip(state);
      downloadBlob(blob, `lumen-vault-${new Date().toISOString().slice(0, 10)}.zip`);
      toast.success("Vault exported. Unzip into your Obsidian vault.");
    } catch (e) {
      console.error(e);
      toast.error("Export failed.");
    }
  }

  function handleClear() {
    if (!confirm("Erase your journal, graph and all follow-ups? This can't be undone.")) return;
    clearState();
    setState({ entries: [], entities: {}, relations: {}, followUps: [] });
    speech.reset();
    toast.success("Journal cleared.");
  }

  return (
    <div className="min-h-screen bg-background">
      <Toaster richColors position="top-center" />
      <header className="border-b bg-card/60 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-full bg-foreground text-background">
              <Sparkles className="h-4 w-4" />
            </div>
            <div>
              <h1 className="font-display text-xl leading-none">Lumen</h1>
              <p className="text-xs text-muted-foreground">a voice-first journal that thinks with you</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={handleExport}
              className="inline-flex items-center gap-2 rounded-md border bg-background px-3 py-2 text-sm font-medium hover:bg-muted"
            >
              <Download className="h-4 w-4" />
              <span className="hidden sm:inline">Export to Obsidian</span>
            </button>
            <button
              onClick={handleClear}
              title="Clear journal"
              className="inline-flex items-center gap-2 rounded-md border bg-background px-2.5 py-2 text-sm text-muted-foreground hover:bg-muted hover:text-destructive"
            >
              <Trash2 className="h-4 w-4" />
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {!speech.supported && hydrated && (
          <div className="mb-6 flex items-start gap-3 rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm">
            <AlertCircle className="mt-0.5 h-4 w-4 text-destructive" />
            <div>
              <p className="font-medium text-foreground">Voice input not supported in this browser.</p>
              <p className="text-muted-foreground">Try Chrome, Edge, or Safari. You can still type into the box below.</p>
            </div>
          </div>
        )}

        {/* Capture card */}
        <section className="rounded-2xl border bg-card p-6 shadow-[var(--shadow-paper)] sm:p-8">
          <div className="grid gap-6 sm:grid-cols-[auto_1fr] sm:items-start">
            <div className="flex flex-col items-center gap-3 sm:items-start">
              <button
                onClick={toggleListening}
                disabled={!speech.supported && !speech.transcript}
                className={`relative flex h-20 w-20 items-center justify-center rounded-full text-background transition-all ${
                  speech.listening
                    ? "mic-pulse bg-accent text-foreground"
                    : "bg-foreground hover:scale-105"
                }`}
                aria-label={speech.listening ? "Stop recording" : "Start recording"}
              >
                {speech.listening ? <MicOff className="h-7 w-7" /> : <Mic className="h-7 w-7" />}
              </button>
              <div className="text-center sm:text-left">
                <p className="font-display text-sm">
                  {speech.listening ? "Listening…" : thinking ? "Thinking…" : "Tap to speak"}
                </p>
                <p className="text-xs text-muted-foreground">
                  {speech.listening ? "Tap again when finished." : "Anything on your mind."}
                </p>
              </div>
            </div>

            <div>
              <div
                ref={transcriptRef}
                className="min-h-[140px] max-h-[260px] overflow-y-auto rounded-lg border bg-background/60 p-4 font-display text-lg leading-relaxed"
              >
                {speech.transcript || speech.interim ? (
                  <>
                    <span>{speech.transcript}</span>
                    {speech.interim && <span className="text-muted-foreground"> {speech.interim}</span>}
                  </>
                ) : (
                  <span className="text-muted-foreground">
                    Your words will appear here. Try: <em>"I had coffee with Maya at the Mission cafe and we talked about the new climate project she's starting at Helio."</em>
                  </span>
                )}
              </div>

              {/* Manual textarea fallback */}
              {!speech.listening && !thinking && (
                <details className="mt-3 text-xs text-muted-foreground">
                  <summary className="cursor-pointer hover:text-foreground">or type instead</summary>
                  <textarea
                    className="mt-2 w-full resize-y rounded-md border bg-background p-3 text-sm text-foreground"
                    rows={3}
                    placeholder="Type a journal entry…"
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                        const v = (e.target as HTMLTextAreaElement).value;
                        processUtterance(v, { followUpId: activeFollowUpId ?? undefined });
                        (e.target as HTMLTextAreaElement).value = "";
                      }
                    }}
                  />
                  <p className="mt-1 text-[11px]">⌘/Ctrl + Enter to submit</p>
                </details>
              )}

              {speech.error && (
                <p className="mt-2 text-xs text-destructive">Mic error: {speech.error}</p>
              )}
              {thinking && (
                <p className="mt-3 inline-flex items-center gap-2 text-xs text-muted-foreground">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" /> Building your graph…
                </p>
              )}
            </div>
          </div>
        </section>

        {/* Follow-up */}
        {openFollowUp && (
          <section className="ink-rise mt-6 rounded-2xl border-2 border-dashed border-accent bg-amber-soft/40 p-6">
            <p className="text-[11px] uppercase tracking-[0.2em] text-muted-foreground">Lumen wonders</p>
            <p className="mt-2 font-display text-2xl leading-snug text-foreground">{openFollowUp.question}</p>
            {openFollowUp.reason && (
              <p className="mt-2 text-sm italic text-muted-foreground">why: {openFollowUp.reason}</p>
            )}
            <div className="mt-4 flex flex-wrap gap-2">
              <button
                onClick={() => answerByVoice(openFollowUp.id)}
                className="inline-flex items-center gap-2 rounded-md bg-foreground px-4 py-2 text-sm font-medium text-background hover:opacity-90"
              >
                <Mic className="h-4 w-4" /> Answer by voice
              </button>
              <button
                onClick={() => setState((s) => answerFollowUp(s, openFollowUp.id))}
                className="rounded-md border bg-background px-4 py-2 text-sm text-muted-foreground hover:text-foreground"
              >
                Skip
              </button>
            </div>
          </section>
        )}

        {/* Graph / list */}
        <section className="mt-8">
          <div className="mb-3 flex items-end justify-between">
            <div>
              <h2 className="font-display text-2xl">Your knowledge graph</h2>
              <p className="text-sm text-muted-foreground">
                {entities.length} {entities.length === 1 ? "entity" : "entities"} · {relations.length} relations · {state.entries.length} entries
              </p>
            </div>
            <div className="inline-flex rounded-md border bg-background p-0.5">
              <button
                onClick={() => setView("graph")}
                className={`inline-flex items-center gap-1.5 rounded px-3 py-1.5 text-sm transition-colors ${view === "graph" ? "bg-foreground text-background" : "text-muted-foreground hover:text-foreground"}`}
              >
                <Network className="h-4 w-4" /> Graph
              </button>
              <button
                onClick={() => setView("list")}
                className={`inline-flex items-center gap-1.5 rounded px-3 py-1.5 text-sm transition-colors ${view === "list" ? "bg-foreground text-background" : "text-muted-foreground hover:text-foreground"}`}
              >
                <List className="h-4 w-4" /> List
              </button>
            </div>
          </div>
          {view === "graph" ? (
            <GraphView entities={entities} relations={relations} highlightId={highlight} onSelect={setHighlight} />
          ) : (
            <EntityList entities={entities} relations={relations} highlightId={highlight} onSelect={setHighlight} />
          )}
        </section>

        {/* Recent entries */}
        {state.entries.length > 0 && (
          <section className="mt-10">
            <h2 className="font-display text-2xl">Recent entries</h2>
            <ul className="mt-3 space-y-3">
              {state.entries.slice(0, 6).map((e) => (
                <li key={e.id} className="rounded-lg border bg-card p-4">
                  <p className="text-[11px] uppercase tracking-wider text-muted-foreground">
                    {new Date(e.createdAt).toLocaleString()}
                  </p>
                  <p className="mt-1 font-display text-base leading-relaxed">{e.text}</p>
                  {e.entityIds.length > 0 && (
                    <p className="mt-2 text-xs text-muted-foreground">
                      → {e.entityIds.map((id) => state.entities[id]?.name).filter(Boolean).join(", ")}
                    </p>
                  )}
                </li>
              ))}
            </ul>
          </section>
        )}

        <footer className="mt-16 border-t pt-6 text-center text-xs text-muted-foreground">
          Lumen stores your journal locally in this browser. Nothing leaves your device except the text Lumen analyzes for entities.
        </footer>
      </main>
    </div>
  );
}

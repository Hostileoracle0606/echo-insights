import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import {
  Bot,
  Keyboard,
  Loader2,
  Mic,
  MicOff,
  Send,
  Volume2,
  Waves,
} from "lucide-react";

import { cn } from "@/lib/utils";

export const Route = createFileRoute("/dock-preview")({ component: DockPreview });

/**
 * Mockup of the Dynamic-Island-style morphing pill.
 *
 * The whole point of this route: validate the morph feel in isolation before
 * we touch the production dock in routes/index.tsx. Toggle modes via the
 * controls panel and watch the capsule width + height animate together while
 * the rounded-full shape never breaks. If the spring feels right here, we
 * port the inner JSX into the real dock; if it doesn't, we iterate without
 * regression risk to the live app.
 */

type Mode = "idle" | "listening" | "speaking" | "thinking" | "typing" | "follow-up";

const MODES: Mode[] = ["idle", "listening", "speaking", "thinking", "typing", "follow-up"];

const SAMPLE_USER =
  "I had coffee with Maya this morning and she mentioned the Atlas migration is being delayed again, and honestly I'm not sure how I feel about it";
const SAMPLE_AGENT = "How long have you been turning this over with Maya?";
const SAMPLE_FOLLOW_UP = "What about the Atlas timeline keeps surfacing?";

function DockPreview() {
  const [mode, setMode] = useState<Mode>("idle");
  const [userText, setUserText] = useState(SAMPLE_USER);
  const [agentText, setAgentText] = useState(SAMPLE_AGENT);
  const [autoCycle, setAutoCycle] = useState(false);

  // Auto-cycle: every 2.2s, advance to the next mode. Useful for watching
  // collapse → expand → re-expand transitions back-to-back without tapping.
  useEffect(() => {
    if (!autoCycle) return;
    const id = window.setInterval(() => {
      setMode((current) => {
        const i = MODES.indexOf(current);
        return MODES[(i + 1) % MODES.length];
      });
    }, 2200);
    return () => window.clearInterval(id);
  }, [autoCycle]);

  const isExpanded = mode !== "idle";

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="mx-auto max-w-3xl px-6 pb-48 pt-12">
        <h1 className="font-display text-3xl">Dock preview</h1>
        <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
          Mockup of the morphing pill. The capsule width and height animate together with a slightly
          overshooting easing curve; the inner content opacity-fades asymmetrically (slower in,
          faster out) so the shape always leads the content. Toggle a mode below.
        </p>

        <section className="mt-10 space-y-6">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
              Mode
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {MODES.map((m) => (
                <button
                  key={m}
                  type="button"
                  onClick={() => {
                    setAutoCycle(false);
                    setMode(m);
                  }}
                  className={cn(
                    "rounded-full border px-3 py-1.5 text-xs font-medium transition",
                    mode === m
                      ? "border-foreground bg-foreground text-background"
                      : "border-border bg-card text-muted-foreground hover:bg-background hover:text-foreground",
                  )}
                >
                  {m}
                </button>
              ))}
              <button
                type="button"
                onClick={() => setAutoCycle((current) => !current)}
                className={cn(
                  "rounded-full border px-3 py-1.5 text-xs font-medium transition",
                  autoCycle
                    ? "border-accent bg-accent/20 text-foreground"
                    : "border-border bg-card text-muted-foreground hover:bg-background hover:text-foreground",
                )}
              >
                {autoCycle ? "Auto-cycling…" : "Auto-cycle"}
              </button>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <label className="flex flex-col gap-2">
              <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                User transcript
              </span>
              <textarea
                value={userText}
                onChange={(event) => setUserText(event.target.value)}
                rows={3}
                className="w-full rounded-lg border bg-card px-3 py-2 text-sm leading-snug outline-none transition focus:border-foreground"
              />
            </label>
            <label className="flex flex-col gap-2">
              <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted-foreground">
                Agent line
              </span>
              <textarea
                value={agentText}
                onChange={(event) => setAgentText(event.target.value)}
                rows={3}
                className="w-full rounded-lg border bg-card px-3 py-2 text-sm leading-snug outline-none transition focus:border-foreground"
              />
            </label>
          </div>

          <div className="rounded-lg border bg-card/60 p-4 text-xs text-muted-foreground">
            <p className="font-medium text-foreground">What to look for</p>
            <ul className="mt-2 space-y-1 list-disc pl-5">
              <li>Width and height animate <em>together</em> — never one then the other.</li>
              <li>The capsule stays a true pill (rounded-full) at every frame.</li>
              <li>Content fades in <em>after</em> the shape settles, fades out <em>before</em> it collapses.</li>
              <li>Slight overshoot at the end of each transition (the spring).</li>
            </ul>
          </div>
        </section>
      </div>

      <DockPill
        mode={mode}
        userText={userText}
        agentText={agentText}
        isExpanded={isExpanded}
        onClickKeyboard={() => setMode((m) => (m === "typing" ? "idle" : "typing"))}
        onClickMic={() => setMode((m) => (m === "listening" ? "idle" : "listening"))}
      />
    </div>
  );
}

interface DockPillProps {
  mode: Mode;
  userText: string;
  agentText: string;
  isExpanded: boolean;
  onClickKeyboard: () => void;
  onClickMic: () => void;
}

function DockPill({
  mode,
  userText,
  agentText,
  isExpanded,
  onClickKeyboard,
  onClickMic,
}: DockPillProps) {
  const listening = mode === "listening";
  const speaking = mode === "speaking";
  const thinking = mode === "thinking";
  const typing = mode === "typing";
  const followUp = mode === "follow-up";

  const voiceActive = listening || speaking;

  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-6 z-20 flex justify-center px-4">
      {/* Hidden SVG hosting the goo filter. Defined once at the dock level so
       * `filter: url(#dock-goo)` resolves anywhere on the page. width/height 0
       * + absolute positioning keeps it out of layout.
       *
       * Filter pipeline:
       *   1. blur            — soft halo around all source pixels
       *   2. colorMatrix     — alpha cliff at ~0.39, fuses pill+blobs into one
       *                        sharp-edged "goo" silhouette (the fill)
       *   3. erode goo       — 1px-smaller copy of the silhouette
       *   4. goo OUT eroded  — subtraction: a 1px ring along the bumpy edge
       *   5. flood + IN      — colors that ring with --color-border
       *   6. merge           — paint goo (fill) below, ring (border) above
       *
       * Without steps 3–6 the silhouette has no visible border — a CSS border
       * on the source pill gets dissolved by step 1's blur, so the outline
       * has to be re-introduced *after* the threshold. */}
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
            <feFlood
              style={{ floodColor: "var(--color-border)" }}
              result="bordercolor"
            />
            <feComposite in="bordercolor" in2="ring" operator="in" result="coloredOutline" />
            <feMerge>
              <feMergeNode in="goo" />
              <feMergeNode in="coloredOutline" />
            </feMerge>
          </filter>
        </defs>
      </svg>
      <div
        // .goo-active applies `filter: url(#dock-goo)` which fuses the pill
        // and its sibling blobs into one mercury silhouette. The wrapper
        // sizes to the pill (relative + inline children) so blob percentages
        // ride the morphing pill's edges automatically.
        className={cn(
          "pointer-events-auto relative",
          voiceActive && "goo-active",
        )}
      >
        {voiceActive && (
          <>
            <span className="goo-blob goo-blob-t1" />
            <span className="goo-blob goo-blob-t2" />
            <span className="goo-blob goo-blob-b1" />
            <span className="goo-blob goo-blob-b2" />
          </>
        )}
        <div
          // Single morphing capsule:
          //  - rounded-full always (shape stays a pill at every frame)
          //  - grid w/ two rows: expanding content above, fixed buttons below
          //  - grid-template-rows transitions 0fr → 1fr to animate to height:auto
          //  - width transitions narrow-pill → wide-pill
          //  - cubic-bezier(.34, 1.56, .64, 1) gives the soft overshoot ("spring")
          //  - voice modes drop border + shadow because the wrapping goo
          //    filter would harden the 1px border into a chunky wavy stroke
          //    and the soft drop-shadow into an ugly outline. The mercury
          //    silhouette IS the visual; non-voice modes keep border/shadow.
          //  - bg-card/95 → bg-card in voice modes: goo's threshold matrix
          //    cleanly handles partial alpha but solid card reads as
          //    intended liquid; the /95 is for backdrop-blur readability,
          //    irrelevant here.
          className={cn(
            "grid overflow-hidden rounded-full backdrop-blur",
            "transition-[grid-template-rows,width] duration-500 ease-[cubic-bezier(0.34,1.56,0.64,1)]",
            voiceActive
              ? "bg-card"
              : "border bg-card/95 shadow-[var(--shadow-paper)]",
            isExpanded
              ? "w-[min(560px,calc(100vw-2rem))] grid-rows-[1fr_auto]"
              : "w-[180px] grid-rows-[0fr_auto]",
          )}
        >
        <div className="overflow-hidden">
          <div
            // Inner content opacity asymmetry:
            //  - expanding: wait 200ms (capsule grows first), then fade in 300ms
            //  - collapsing: snap to opacity-0 in 120ms (content clears before
            //    the capsule shrinks). Without this asymmetry the morph reads
            //    as "two boxes stacked", not "one shape that grew".
            //
            // min-h-[68px] + items-center: the button row below is ~60px tall
            // (h-12 mic + p-1.5 padding), so a one-line transcript squished
            // against it reads as "ribbon glued to dock". Giving content a
            // 68px envelope with vertical centering balances the visual weight
            // of the controls and keeps the capsule feeling like one body.
            className={cn(
              "flex min-h-[68px] items-center px-5 py-3 transition-opacity",
              isExpanded
                ? "opacity-100 duration-300 delay-200"
                : "opacity-0 duration-100 delay-0",
            )}
          >
            {typing ? (
              <form className="flex items-center gap-3" onSubmit={(e) => e.preventDefault()}>
                <Keyboard className="h-4 w-4 shrink-0 text-muted-foreground" />
                <input
                  placeholder="Type a thought…"
                  className="flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
                />
                <button
                  type="submit"
                  aria-label="Send"
                  className="inline-flex h-8 w-8 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground"
                >
                  <Send className="h-4 w-4" />
                </button>
              </form>
            ) : speaking ? (
              <div className="flex w-full items-center justify-center gap-3 text-sm">
                <Bot className="h-4 w-4 shrink-0 text-accent" />
                <span className="max-h-32 max-w-[85%] overflow-y-auto text-center leading-snug text-foreground">
                  {agentText || "…"}
                </span>
              </div>
            ) : listening ? (
              <div className="flex w-full items-center justify-center gap-3 text-sm">
                <Waves className="h-4 w-4 shrink-0 text-accent" />
                <span className="max-h-32 max-w-[85%] overflow-y-auto text-center leading-snug">
                  {userText ? (
                    <span className="text-foreground">{userText}</span>
                  ) : (
                    <span className="text-muted-foreground">Listening…</span>
                  )}
                </span>
              </div>
            ) : thinking ? (
              <div className="flex w-full items-center justify-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
                <span>Mapping your thought…</span>
              </div>
            ) : followUp ? (
              <div className="flex w-full items-center justify-center gap-3 text-sm">
                <Bot className="h-4 w-4 shrink-0 text-muted-foreground" />
                <span className="max-w-[85%] text-center leading-snug text-muted-foreground">
                  {SAMPLE_FOLLOW_UP}
                </span>
              </div>
            ) : null}
          </div>
        </div>

        <div className="flex items-center justify-center gap-1 p-1.5">
          <button
            type="button"
            onClick={onClickKeyboard}
            aria-pressed={typing}
            className={cn(
              "inline-flex h-11 w-11 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground",
              typing && "bg-background text-foreground",
            )}
          >
            <Keyboard className="h-[18px] w-[18px]" />
          </button>
          <button
            type="button"
            onClick={onClickMic}
            className={cn(
              "relative inline-flex h-12 w-12 items-center justify-center rounded-full transition",
              listening
                ? "bg-accent text-foreground"
                : "bg-foreground text-background hover:scale-105",
            )}
          >
            {listening ? <MicOff className="h-[18px] w-[18px]" /> : <Mic className="h-[18px] w-[18px]" />}
          </button>
          <button
            type="button"
            className="inline-flex h-11 w-11 items-center justify-center rounded-full text-muted-foreground transition hover:bg-background hover:text-foreground"
          >
            <Volume2 className="h-[18px] w-[18px]" />
          </button>
        </div>
      </div>
      </div>
    </div>
  );
}

#!/usr/bin/env python3
"""
Lumen / Echo-Insights demo runner.

Drives the Lumen UI through a fully-scripted, VOICE-FIRST walkthrough so you
can record a Loom without a real microphone, without burning real API credits,
and without any timing flakiness from live AI calls.

How the illusion works
----------------------
* Chromium launches with --use-fake-ui-for-media-stream and
  --use-fake-device-for-media-stream so navigator.mediaDevices.getUserMedia
  resolves with a virtual mic — no permission prompt, no real audio capture.
* `window.WebSocket` is replaced (only for the Gemini Live URL) with a mock
  that auto-responds to the setup frame, then waits for Python to inject
  serverContent frames carrying user / agent transcripts and turn signals.
* Gemini's REST extraction endpoint is intercepted with `page.route` and
  answered with canned graph patches — that's how entities pop into the
  graph as the "user" speaks.
* Every "spoken" line and Lumen reply is hard-coded in the TURNS list below.
  Edit it to change what the demo says.

Quick start
-----------
    pip install -r scripts/requirements.txt
    python -m playwright install chromium
    python scripts/demo.py

Flags
-----
    --no-server     Skip auto-starting the dev server.
    --url URL       Override URL (default http://localhost:8080).
    --speed FLOAT   Pause multiplier. 1.0 default; 1.5 slower; 0.5 faster.
    --viewport WxH  Viewport, default 1280x720.
    --headless      Run without a visible window (smoke test only).
    --keep-open     Hold the browser open at the end.
    --clear-at-end  Click Clear-journal as the last step.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    from playwright.async_api import (
        Page,
        Route,
        async_playwright,
    )
except ImportError:
    sys.stderr.write(
        "playwright is not installed. Run:\n"
        "    pip install -r scripts/requirements.txt\n"
        "    python -m playwright install chromium\n"
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Demo content. Each TURN is one voice round-trip:
#   user_says     — broken into chunks; each chunk arrives as inputTranscription
#   agent_says    — broken into chunks; each chunk arrives as outputTranscription
#   entities/relations — what the (mocked) extractor returns for that turn
#   spotlight     — which sidebar piece to ring-highlight after the extraction
#
# Allowed entity types (zod schema in src/lib/extract-graph.ts):
#   person | place | organization | project | event | object | other
# ---------------------------------------------------------------------------


def chunks(text: str, parts_count: int = 3) -> list[str]:
    """Split a string into ~`parts_count` chunks, preserving spaces. The last
    chunk keeps the trailing punctuation so onUserSentence fires once at end."""
    words = text.split(" ")
    if not words:
        return [text]
    parts_count = max(1, min(parts_count, len(words)))
    size = max(1, len(words) // parts_count)
    out: list[str] = []
    i = 0
    while i < len(words):
        end = min(len(words), i + size)
        # Make sure the final chunk swallows everything left so the last
        # token (with its punctuation) is the actual end of the utterance.
        if len(out) == parts_count - 1:
            end = len(words)
        chunk = " ".join(words[i:end])
        # Add a leading space for non-first chunks so the dock display
        # shows them separated naturally.
        if out:
            chunk = " " + chunk
        out.append(chunk)
        i = end
    return out


TURNS: list[dict[str, Any]] = [
    {
        "chapter": "Coffee with Maya",
        "narrate": "User speaks about coffee with Maya — Lumen quietly extracts the entities.",
        "user_says": (
            "I had coffee with Maya at the new café on Phillip Street yesterday. "
            "We talked about her switching from Pure Math to Stats."
        ),
        "agent_says": (
            "Got it — Maya's switching from Pure Math to Stats. "
            "How long have you known her?"
        ),
        "entities": [
            {
                "name": "Maya",
                "type": "person",
                "description": "Friend; recently switching from Pure Math to Stats.",
                "metadata": {"program": "Stats", "previously": "Pure Math"},
                "questions": [
                    "How long have you known Maya?",
                    "What's drawing her toward Stats?",
                    "Where did the two of you first meet?",
                ],
            },
            {
                "name": "Phillip Street Café",
                "type": "place",
                "description": "New café on Phillip Street; meet-up spot.",
                "questions": [
                    "What's the vibe of the new place?",
                    "Is it becoming a regular spot?",
                ],
            },
            {
                "name": "Pure Math",
                "type": "other",
                "description": "Maya's previous program of study.",
                "questions": ["What did Maya like or not like about Pure Math?"],
            },
            {
                "name": "Stats",
                "type": "other",
                "description": "Maya's new direction.",
                "questions": ["What sparked the move toward Stats?"],
            },
        ],
        "relations": [
            {"source": "Maya", "target": "Phillip Street Café", "label": "met_at"},
            {"source": "Maya", "target": "Pure Math", "label": "switching_from"},
            {"source": "Maya", "target": "Stats", "label": "switching_to"},
        ],
        "sidebar_beats": [
            ("aside h2", "Entity name & type"),
            ("aside p.text-foreground", "Description Lumen extracted from the audio"),
        ],
    },
    {
        "chapter": "Maya's band",
        "narrate": "User mentions Maya's band — Lumen reuses the Maya node and grows the graph.",
        "user_says": (
            "Maya invited me to her band's gig at the Bombshelter on Friday. "
            "The band is called Hadron and she plays bass."
        ),
        "agent_says": (
            "Maya plays bass in Hadron — that's a new side of her. "
            "How'd you find that out?"
        ),
        "entities": [
            {
                "name": "Hadron",
                "type": "organization",
                "description": "Maya's band; rock outfit playing the Bombshelter.",
                "questions": [
                    "How long has the band been playing together?",
                    "What's their sound like?",
                ],
            },
            {
                "name": "Bombshelter",
                "type": "place",
                "description": "Local venue hosting Hadron's gig on Friday.",
                "questions": ["Have you been to the Bombshelter before?"],
            },
        ],
        "relations": [
            {"source": "Maya", "target": "Hadron", "label": "plays_in"},
            {"source": "Hadron", "target": "Bombshelter", "label": "performs_at"},
        ],
        "sidebar_beats": [
            ("aside section:has(svg) ul", "Linked entities — click to navigate"),
        ],
        "navigate_to": "Maya",
        "after_navigate_beat": ("aside h2", "Maya — now richer than turn 1"),
    },
    {
        "chapter": "Project pitch",
        "narrate": "User pitches a project — Lumen connects it back to Maya.",
        "user_says": (
            "I'm thinking of pitching a side project — a small AI that summarizes "
            "old journals. Maya might want in. I'd build it on Cloudflare Workers."
        ),
        "agent_says": (
            "Memo could be a real thing — what makes summarizing your old journals "
            "worth doing right now?"
        ),
        "entities": [
            {
                "name": "Memo",
                "type": "project",
                "description": "Side project idea: an AI that summarizes old journals.",
                "metadata": {"stack": "Cloudflare Workers", "stage": "idea"},
                "questions": [
                    "What problem is Memo really solving for you?",
                    "Who would the first users be?",
                    "What does a v1 look like?",
                ],
            },
            {
                "name": "Cloudflare Workers",
                "type": "other",
                "description": "Edge runtime Memo would be built on.",
                "questions": ["Why Workers over a more traditional backend?"],
            },
        ],
        "relations": [
            {"source": "Memo", "target": "Cloudflare Workers", "label": "built_on"},
            {"source": "Maya", "target": "Memo", "label": "might_join"},
        ],
        "sidebar_beats": [
            ("aside dl", "Metadata Lumen captured from the conversation"),
        ],
        "navigate_to": "Maya",
        "after_navigate_beat": ("aside p.text-xs", "Mention count grows over time"),
    },
]


GRANULAR_DEMO: dict[str, Any] = {
    "user_says": (
        "Quick reminder — meeting Sam at the library on Friday morning. "
        "Bass practice with Hadron right after."
    ),
    "agent_says_granular": (
        "Granular mode — every named thing landed: Sam, the library, "
        "even Friday and the bass."
    ),
    "agent_says_wiki": (
        "Library on Friday with Sam — noted. Want me to ask about Sam later, "
        "or is this just logistics?"
    ),
    "wiki_entities": [
        {
            "name": "Sam",
            "type": "person",
            "description": "Meeting at the library Friday morning.",
            "questions": ["How do you know Sam?", "What's the meeting about?"],
        },
        {
            "name": "Library",
            "type": "place",
            "description": "Where Sam and you are meeting Friday.",
            "questions": ["Which library — campus or downtown?"],
        },
    ],
    "wiki_relations": [
        {"source": "Sam", "target": "Library", "label": "meeting_at"},
    ],
    "granular_extras_entities": [
        {"name": "Friday", "type": "event", "description": "Specific day flagged on the calendar."},
        {"name": "Bass", "type": "object", "description": "Maya's instrument."},
    ],
    "granular_extras_relations": [
        {"source": "Sam", "target": "Friday", "label": "scheduled_on"},
        {"source": "Maya", "target": "Bass", "label": "plays"},
    ],
}


# ---------------------------------------------------------------------------
# Mock Gemini REST response (graph extraction).
# ---------------------------------------------------------------------------


def gemini_function_call_response(
    entities: list[dict[str, Any]],
    relations: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "candidates": [
            {
                "content": {
                    "role": "model",
                    "parts": [
                        {
                            "functionCall": {
                                "name": "extract_graph",
                                "args": {"entities": entities, "relations": relations},
                            }
                        }
                    ],
                },
                "finishReason": "STOP",
                "index": 0,
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 100,
            "candidatesTokenCount": 50,
            "totalTokenCount": 150,
        },
    }


# ---------------------------------------------------------------------------
# Cue-card narration.
# ---------------------------------------------------------------------------


def cue(line: str, *, kind: str = "info") -> None:
    glyph = {"info": "•", "step": "▶", "ok": "✓", "warn": "!"}.get(kind, "·")
    sys.stdout.write(f"  {glyph} {line}\n")
    sys.stdout.flush()


def banner(title: str) -> None:
    bar = "─" * (len(title) + 4)
    sys.stdout.write(f"\n{bar}\n  {title}\n{bar}\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Dev-server lifecycle.
# ---------------------------------------------------------------------------


def port_open(host: str, port: int, timeout: float = 0.4) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        try:
            s.connect((host, port))
        except OSError:
            return False
        return True


def wait_for_port(host: str, port: int, timeout: float = 60.0) -> bool:
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if port_open(host, port):
            return True
        time.sleep(0.5)
    return False


def start_dev_server(project_dir: Path) -> subprocess.Popen[bytes] | None:
    runner = "bun" if shutil.which("bun") else ("npm" if shutil.which("npm") else None)
    if runner is None:
        cue("Neither `bun` nor `npm` is on PATH — start the dev server manually.", kind="warn")
        return None
    cmd = [runner, "run", "dev"] if runner == "npm" else ["bun", "dev"]
    cue(f"Starting dev server: {' '.join(cmd)}", kind="step")
    proc = subprocess.Popen(
        cmd,
        cwd=str(project_dir),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc


# ---------------------------------------------------------------------------
# Pacing.
# ---------------------------------------------------------------------------


class Pace:
    def __init__(self, multiplier: float) -> None:
        self.k = max(0.1, multiplier)

    async def beat(self, seconds: float = 0.6) -> None:
        await asyncio.sleep(seconds * self.k)

    async def short(self) -> None:
        await self.beat(0.4)

    async def medium(self) -> None:
        await self.beat(1.2)

    async def long(self) -> None:
        await self.beat(2.4)

    async def dwell(self) -> None:
        await self.beat(4.0)


# ---------------------------------------------------------------------------
# In-page boot script: WebSocket mock + overlay system. Runs before any app
# JS so window.WebSocket is replaced before useGeminiLive ever touches it.
# ---------------------------------------------------------------------------

BOOT_SCRIPT = r"""
(() => {
  if (window.__lumenDemoBooted) return;
  window.__lumenDemoBooted = true;

  // ---------- WebSocket mock ----------
  const RealWS = window.WebSocket;
  const GEMINI_LIVE_HOST = "generativelanguage.googleapis.com";
  let activeMock = null;

  class MockGeminiWS {
    constructor(url, protocols) {
      // For non-Gemini URLs, defer to the real WebSocket. Constructors that
      // return an object replace the `this` binding under `new`, so this
      // path transparently passes through.
      if (!url || url.indexOf(GEMINI_LIVE_HOST) === -1) {
        return new RealWS(url, protocols);
      }
      this.url = url;
      this.readyState = 0; // CONNECTING
      this._listeners = { open: [], message: [], close: [], error: [] };
      this.binaryType = "arraybuffer";
      this.bufferedAmount = 0;
      this.protocol = "";
      this.extensions = "";
      activeMock = this;
      window.__lumenMockGeminiWs = this;
      // Open on a microtask so the caller can attach listeners first.
      queueMicrotask(() => {
        if (this.readyState !== 0) return;
        this.readyState = 1; // OPEN
        this._fire("open", { type: "open" });
      });
    }
    addEventListener(type, fn, opts) {
      if (!this._listeners[type]) this._listeners[type] = [];
      this._listeners[type].push({ fn, once: !!(opts && opts.once) });
    }
    removeEventListener(type, fn) {
      const arr = this._listeners[type];
      if (!arr) return;
      this._listeners[type] = arr.filter((l) => l.fn !== fn);
    }
    set onmessage(fn) { this.addEventListener("message", fn); }
    set onopen(fn)    { this.addEventListener("open", fn); }
    set onclose(fn)   { this.addEventListener("close", fn); }
    set onerror(fn)   { this.addEventListener("error", fn); }
    send(data) {
      // Detect the setup frame; everything else (audio chunks, tool
      // responses, text) is silently consumed.
      let parsed = null;
      if (typeof data === "string") {
        try { parsed = JSON.parse(data); } catch (_) {}
      }
      if (parsed && parsed.setup) {
        // Reply on a real timeout so the React effect cycle settles.
        setTimeout(() => this._frame({ setupComplete: {} }), 30);
      }
    }
    close() {
      if (this.readyState === 3) return;
      this.readyState = 3;
      this._fire("close", { type: "close", code: 1000, reason: "", wasClean: true });
      if (activeMock === this) {
        activeMock = null;
        window.__lumenMockGeminiWs = null;
      }
    }
    _frame(obj) {
      this._fire("message", { type: "message", data: JSON.stringify(obj) });
    }
    _fire(type, ev) {
      const arr = (this._listeners[type] || []).slice();
      for (const l of arr) {
        try { l.fn(ev); } catch (e) { console.warn("[mock-ws] listener threw", e); }
      }
      this._listeners[type] = (this._listeners[type] || []).filter((l) => !l.once);
    }
  }
  // Preserve constants used by callers (e.g. WebSocket.OPEN === 1).
  MockGeminiWS.CONNECTING = 0; MockGeminiWS.OPEN = 1;
  MockGeminiWS.CLOSING = 2;    MockGeminiWS.CLOSED = 3;
  window.WebSocket = MockGeminiWS;

  // External injection points — Python calls these via page.evaluate.
  function withMock(fn) {
    if (!activeMock || activeMock.readyState !== 1) return false;
    fn(activeMock);
    return true;
  }
  window.__lumenInjectUserText = (text) =>
    withMock((m) => m._frame({ serverContent: { inputTranscription: { text } } }));
  window.__lumenInjectAgentText = (text) =>
    withMock((m) => m._frame({ serverContent: { outputTranscription: { text } } }));
  window.__lumenInjectTurnComplete = () =>
    withMock((m) => m._frame({ serverContent: { turnComplete: true } }));
  window.__lumenInjectInterrupted = () =>
    withMock((m) => m._frame({ serverContent: { interrupted: true } }));
  window.__lumenMockReady = () => !!(activeMock && activeMock.readyState === 1);

  // ---------- Overlay system ----------
  // Design language matches src/styles.css:
  //   - paper / ink / amber palette via CSS custom properties (with literal
  //     oklch fallbacks for the brief window before styles.css parses)
  //   - serif Fraunces for titles, Inter for captions, JetBrains Mono for
  //     eyebrows/numbers — same fallback chains as the app
  //   - motion durations (0.5s entrances, 2.6s ease-in-out halo) lifted from
  //     the app's own `ink-rise` and `mic-pulse-thoughtful` keyframes so the
  //     overlay reads as "part of the app" rather than a recorder HUD
  const FRAUNCES = '"Fraunces", "Iowan Old Style", Georgia, serif';
  const INTER    = '"Inter", ui-sans-serif, system-ui, sans-serif';
  const MONO     = '"JetBrains Mono", ui-monospace, SFMono-Regular, monospace';
  const RAISE    = "cubic-bezier(0.16, 1, 0.3, 1)";

  const style = document.createElement("style");
  style.textContent = `
    /* Spotlight ring: a single calm amber outline with a soft halo, paced to
       the app's mic-pulse-thoughtful (2.6s). One ring is reused across beats —
       its position transitions smoothly so it appears to glide between
       targets instead of blinking. */
    .lumen-demo-spot {
      position: fixed;
      z-index: 2147483500;
      pointer-events: none;
      border-radius: 14px;
      border: 1.5px solid oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.62);
      background: oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.04);
      box-shadow: 0 0 0 0 oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.32);
      animation: lumen-demo-spot 2.6s ease-in-out infinite;
      transition:
        left 360ms ${RAISE},
        top 360ms ${RAISE},
        width 360ms ${RAISE},
        height 360ms ${RAISE},
        opacity 240ms ease-out;
      opacity: 0;
    }
    .lumen-demo-spot[data-shown="true"] { opacity: 1; }
    @keyframes lumen-demo-spot {
      0%, 100% { box-shadow: 0 0 0 0 oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.30); }
      50%      { box-shadow: 0 0 0 14px oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0); }
    }

    /* Caption: paper card, ink text — same shadow as the app's --shadow-paper.
       Tiny amber dot prefix for visual rhythm, matches the dock's accent dot. */
    .lumen-demo-caption {
      position: fixed;
      z-index: 2147483550;
      padding: 7px 12px 7px 11px;
      background: var(--card, oklch(0.99 0.008 85));
      color: var(--foreground, oklch(0.18 0.015 50));
      border: 1px solid var(--border, oklch(0.85 0.018 75));
      border-radius: 10px;
      font: 500 12.5px/1.3 ${INTER};
      letter-spacing: 0.002em;
      box-shadow:
        0 1px 2px oklch(0.18 0.015 50 / 0.06),
        0 8px 32px oklch(0.18 0.015 50 / 0.10);
      display: inline-flex;
      align-items: center;
      gap: 8px;
      max-width: min(360px, 70vw);
      pointer-events: none;
      transition: left 360ms ${RAISE}, top 360ms ${RAISE}, opacity 240ms ease-out;
      opacity: 0;
    }
    .lumen-demo-caption[data-shown="true"] { opacity: 1; }
    .lumen-demo-caption-dot {
      width: 6px; height: 6px;
      border-radius: 9999px;
      background: var(--amber, oklch(0.72 0.16 60));
      flex-shrink: 0;
      box-shadow: 0 0 0 3px oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.18);
    }

    /* Chapter chip: bottom-left card. JetBrains Mono number + Fraunces title,
       same composition as the in-app Entity sidebar header. */
    .lumen-demo-chapter {
      position: fixed;
      left: 24px; bottom: 24px;
      z-index: 2147483540;
      padding: 11px 16px 12px;
      background: var(--card, oklch(0.99 0.008 85));
      border: 1px solid var(--border, oklch(0.85 0.018 75));
      border-radius: 12px;
      box-shadow:
        0 1px 2px oklch(0.18 0.015 50 / 0.06),
        0 8px 32px oklch(0.18 0.015 50 / 0.08);
      display: flex; flex-direction: column; gap: 2px;
      pointer-events: none;
      animation: lumen-demo-rise 480ms ${RAISE} both;
      max-width: 320px;
    }
    .lumen-demo-chapter[data-leaving="true"] {
      animation: lumen-demo-fall 240ms ease-in both;
    }
    .lumen-demo-chapter-num {
      font: 500 10px/1 ${MONO};
      letter-spacing: 0.16em;
      text-transform: uppercase;
      color: var(--muted-foreground, oklch(0.42 0.02 60));
    }
    .lumen-demo-chapter-title {
      font: 400 17px/1.15 ${FRAUNCES};
      letter-spacing: -0.005em;
      color: var(--foreground, oklch(0.18 0.015 50));
      font-feature-settings: "ss01", "ss02";
    }
    @keyframes lumen-demo-rise {
      from { opacity: 0; transform: translateY(8px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    @keyframes lumen-demo-fall {
      from { opacity: 1; transform: translateY(0); }
      to   { opacity: 0; transform: translateY(4px); }
    }

    /* HUD badge: persistent bottom-right pill so the viewer always knows this
       is a scripted run. Bottom-right keeps it clear of the app's header
       toolbar (counts / mode toggle / export / clear); mirrors the chapter
       chip in the bottom-left for visual symmetry. */
    .lumen-demo-hud {
      position: fixed;
      bottom: 24px; right: 24px;
      z-index: 2147483520;
      padding: 6px 11px 6px 9px;
      background: oklch(from var(--card, oklch(0.99 0.008 85)) l c h / 0.92);
      backdrop-filter: blur(6px);
      -webkit-backdrop-filter: blur(6px);
      border: 1px solid var(--border, oklch(0.85 0.018 75));
      border-radius: 9999px;
      font: 500 10px/1 ${MONO};
      letter-spacing: 0.14em;
      text-transform: uppercase;
      color: var(--muted-foreground, oklch(0.42 0.02 60));
      display: inline-flex; align-items: center; gap: 7px;
      pointer-events: none;
      box-shadow: 0 1px 2px oklch(0.18 0.015 50 / 0.06);
      animation: lumen-demo-rise 600ms 200ms ${RAISE} both;
    }
    .lumen-demo-hud-dot {
      width: 6px; height: 6px;
      border-radius: 9999px;
      background: var(--amber, oklch(0.72 0.16 60));
      box-shadow: 0 0 0 2px oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.22);
      animation: lumen-demo-hud-blink 2.6s ease-in-out infinite;
    }
    @keyframes lumen-demo-hud-blink {
      0%, 100% { opacity: 1; }
      50%      { opacity: 0.55; }
    }

    /* Title / end card: full-viewport blurred-paper backdrop with a centered
       editorial composition. Matches the warm-paper grain under the blur. */
    .lumen-demo-card {
      position: fixed; inset: 0;
      z-index: 2147483560;
      display: flex; align-items: center; justify-content: center;
      background: oklch(from var(--paper, oklch(0.97 0.012 85)) l c h / 0.80);
      backdrop-filter: blur(8px) saturate(1.05);
      -webkit-backdrop-filter: blur(8px) saturate(1.05);
      pointer-events: none;
      animation: lumen-demo-fade-in 480ms ease-out both;
    }
    .lumen-demo-card[data-leaving="true"] {
      animation: lumen-demo-fade-out 320ms ease-in both;
    }
    .lumen-demo-card-inner {
      text-align: center;
      display: flex; flex-direction: column; align-items: center; gap: 14px;
      animation: lumen-demo-card-rise 720ms ${RAISE} both;
      padding: 0 32px;
    }
    .lumen-demo-card-eyebrow {
      font: 500 11px/1 ${MONO};
      letter-spacing: 0.22em;
      text-transform: uppercase;
      color: var(--muted-foreground, oklch(0.42 0.02 60));
    }
    .lumen-demo-card-title {
      font: 400 64px/1 ${FRAUNCES};
      letter-spacing: -0.024em;
      color: var(--foreground, oklch(0.18 0.015 50));
      font-feature-settings: "ss01", "ss02";
      margin: 4px 0 2px;
    }
    .lumen-demo-card-rule {
      width: 28px; height: 1px;
      background: oklch(from var(--amber, oklch(0.72 0.16 60)) l c h / 0.55);
    }
    .lumen-demo-card-sub {
      font: 400 15px/1.45 ${INTER};
      color: var(--muted-foreground, oklch(0.42 0.02 60));
      max-width: 480px;
    }
    .lumen-demo-card-meta {
      font: 500 10.5px/1 ${MONO};
      letter-spacing: 0.18em;
      text-transform: uppercase;
      color: var(--muted-foreground, oklch(0.42 0.02 60));
      margin-top: 10px;
      opacity: 0.85;
    }
    @keyframes lumen-demo-fade-in  { from { opacity: 0; } to { opacity: 1; } }
    @keyframes lumen-demo-fade-out { from { opacity: 1; } to { opacity: 0; } }
    @keyframes lumen-demo-card-rise {
      from { opacity: 0; transform: translateY(14px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    @media (prefers-reduced-motion: reduce) {
      .lumen-demo-spot,
      .lumen-demo-hud-dot,
      .lumen-demo-chapter,
      .lumen-demo-card,
      .lumen-demo-card-inner { animation: none !important; }
    }
  `;
  const attach = () => document.head && document.head.appendChild(style);
  if (document.head) attach(); else document.addEventListener("DOMContentLoaded", attach);

  // ---------- Spotlight (single shared ring + caption that glide) ----------
  let spotEl = null;
  let capEl  = null;

  function ensureSpot() {
    if (!spotEl) {
      spotEl = document.createElement("div");
      spotEl.className = "lumen-demo-spot";
      document.body.appendChild(spotEl);
    }
    return spotEl;
  }
  function ensureCaption() {
    if (!capEl) {
      capEl = document.createElement("div");
      capEl.className = "lumen-demo-caption";
      const dot = document.createElement("span");
      dot.className = "lumen-demo-caption-dot";
      const txt = document.createElement("span");
      txt.className = "lumen-demo-caption-text";
      capEl.appendChild(dot);
      capEl.appendChild(txt);
      document.body.appendChild(capEl);
    }
    return capEl;
  }

  // Place the caption above the target if there's room, else below — keeps it
  // on-screen even for elements near the top of the viewport.
  function positionCaption(cap, rect, pad) {
    // Force layout so width is measured before we use it for clamping.
    const cw = cap.offsetWidth || 220;
    const ch = cap.offsetHeight || 32;
    const margin = 10;
    const wantTop = rect.top - pad - ch - 8;
    const top = wantTop >= 12
      ? wantTop
      : Math.min(window.innerHeight - ch - 12, rect.bottom + pad + 8);
    let left = rect.left + rect.width / 2 - cw / 2;
    left = Math.max(margin, Math.min(window.innerWidth - cw - margin, left));
    cap.style.left = left + "px";
    cap.style.top  = top  + "px";
  }

  window.__lumenDemoOverlay = {
    spotlight(selector, caption) {
      const target = document.querySelector(selector);
      if (!target) return false;
      const r = target.getBoundingClientRect();
      const pad = 10;
      const ring = ensureSpot();
      ring.style.left   = (r.left - pad) + "px";
      ring.style.top    = (r.top  - pad) + "px";
      ring.style.width  = (r.width  + pad * 2) + "px";
      ring.style.height = (r.height + pad * 2) + "px";
      ring.dataset.shown = "true";

      if (caption) {
        const cap = ensureCaption();
        cap.querySelector(".lumen-demo-caption-text").textContent = caption;
        cap.dataset.shown = "true";
        // Two-frame defer so width measurement uses the new text.
        requestAnimationFrame(() => requestAnimationFrame(() => positionCaption(cap, r, pad)));
      } else if (capEl) {
        capEl.dataset.shown = "false";
      }
      return true;
    },
    clearSpotlight() {
      if (spotEl) spotEl.dataset.shown = "false";
      if (capEl)  capEl.dataset.shown  = "false";
    },

    // ---------- Chapter chip (bottom-left) ----------
    setChapter(num, title) {
      this.clearChapter();
      const chip = document.createElement("div");
      chip.className = "lumen-demo-chapter";
      if (num) {
        const n = document.createElement("span");
        n.className = "lumen-demo-chapter-num";
        n.textContent = num;
        chip.appendChild(n);
      }
      const t = document.createElement("span");
      t.className = "lumen-demo-chapter-title";
      t.textContent = title;
      chip.appendChild(t);
      document.body.appendChild(chip);
    },
    clearChapter() {
      const existing = document.querySelectorAll(".lumen-demo-chapter");
      existing.forEach((el) => {
        el.dataset.leaving = "true";
        setTimeout(() => el.remove(), 260);
      });
    },

    // ---------- HUD badge (top-right) ----------
    mountHud(label) {
      this.unmountHud();
      const hud = document.createElement("div");
      hud.className = "lumen-demo-hud";
      const dot = document.createElement("span");
      dot.className = "lumen-demo-hud-dot";
      const txt = document.createElement("span");
      txt.textContent = label;
      hud.appendChild(dot);
      hud.appendChild(txt);
      document.body.appendChild(hud);
    },
    unmountHud() {
      document.querySelectorAll(".lumen-demo-hud").forEach((el) => el.remove());
    },

    // ---------- Title / end card ----------
    showCard(opts) {
      this.hideCard(true);
      const card = document.createElement("div");
      card.className = "lumen-demo-card";
      const inner = document.createElement("div");
      inner.className = "lumen-demo-card-inner";
      if (opts.eyebrow) {
        const e = document.createElement("div");
        e.className = "lumen-demo-card-eyebrow";
        e.textContent = opts.eyebrow;
        inner.appendChild(e);
      }
      if (opts.title) {
        const t = document.createElement("div");
        t.className = "lumen-demo-card-title";
        t.textContent = opts.title;
        inner.appendChild(t);
      }
      const rule = document.createElement("div");
      rule.className = "lumen-demo-card-rule";
      inner.appendChild(rule);
      if (opts.sub) {
        const s = document.createElement("div");
        s.className = "lumen-demo-card-sub";
        s.textContent = opts.sub;
        inner.appendChild(s);
      }
      if (opts.meta) {
        const m = document.createElement("div");
        m.className = "lumen-demo-card-meta";
        m.textContent = opts.meta;
        inner.appendChild(m);
      }
      card.appendChild(inner);
      document.body.appendChild(card);
    },
    hideCard(immediate) {
      const cards = document.querySelectorAll(".lumen-demo-card");
      cards.forEach((el) => {
        if (immediate) { el.remove(); return; }
        el.dataset.leaving = "true";
        setTimeout(() => el.remove(), 340);
      });
    },
    fontsReady() {
      return (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
    },
  };
})();
"""


async def install_boot_script(page: Page) -> None:
    await page.add_init_script(BOOT_SCRIPT)


async def spotlight(page: Page, selector: str, caption: str = "") -> None:
    await page.evaluate(
        "([s, c]) => window.__lumenDemoOverlay && window.__lumenDemoOverlay.spotlight(s, c)",
        [selector, caption],
    )


async def wait_for_fonts(page: Page) -> None:
    """Block until web fonts (Fraunces / Inter / JetBrains Mono) load.

    Without this the title card briefly renders in fallback Georgia before
    swapping to Fraunces — visible as a flicker on the first frame of the
    recording. The app loads fonts via Google Fonts <link> tags in the HTML
    head, so document.fonts.ready resolves once they're decoded.
    """
    try:
        await page.evaluate("window.__lumenDemoOverlay.fontsReady()")
    except Exception:
        pass


async def title_card(
    page: Page,
    *,
    eyebrow: str,
    title: str,
    sub: str = "",
    meta: str = "",
    hold: float = 1.7,
    pace: "Pace | None" = None,
) -> None:
    await page.evaluate(
        "(o) => window.__lumenDemoOverlay.showCard(o)",
        {"eyebrow": eyebrow, "title": title, "sub": sub, "meta": meta},
    )
    multiplier = pace.k if pace else 1.0
    await asyncio.sleep(hold * max(0.4, multiplier))
    await page.evaluate("() => window.__lumenDemoOverlay.hideCard(false)")
    await asyncio.sleep(0.34)


async def end_card(
    page: Page,
    *,
    eyebrow: str,
    title: str,
    sub: str = "",
    meta: str = "",
    hold: float = 2.4,
    pace: "Pace | None" = None,
) -> None:
    await page.evaluate(
        "(o) => window.__lumenDemoOverlay.showCard(o)",
        {"eyebrow": eyebrow, "title": title, "sub": sub, "meta": meta},
    )
    multiplier = pace.k if pace else 1.0
    await asyncio.sleep(hold * max(0.4, multiplier))


async def set_chapter(page: Page, num: str | None, title: str) -> None:
    await page.evaluate(
        "([n, t]) => window.__lumenDemoOverlay.setChapter(n, t)",
        [num, title],
    )


async def clear_chapter(page: Page) -> None:
    await page.evaluate("() => window.__lumenDemoOverlay.clearChapter()")


async def mount_hud(page: Page, label: str) -> None:
    await page.evaluate(
        "(l) => window.__lumenDemoOverlay.mountHud(l)",
        label,
    )


async def clear_spotlight(page: Page) -> None:
    await page.evaluate("window.__lumenDemoOverlay && window.__lumenDemoOverlay.clearSpotlight()")


# ---------------------------------------------------------------------------
# Voice-turn driver — feeds transcripts through the mock WebSocket so the
# Gemini Live hook reacts as if it were a real conversation.
# ---------------------------------------------------------------------------


async def inject_user_text(page: Page, chunk: str) -> None:
    await page.evaluate("(t) => window.__lumenInjectUserText(t)", chunk)


async def inject_agent_text(page: Page, chunk: str) -> None:
    await page.evaluate("(t) => window.__lumenInjectAgentText(t)", chunk)


async def inject_turn_complete(page: Page) -> None:
    await page.evaluate("() => window.__lumenInjectTurnComplete()")


async def speak_user(page: Page, text: str, pace: Pace) -> None:
    """Stream user transcript chunks into the dock — last chunk carries the
    sentence-ending punctuation so onUserSentence fires once at end."""
    parts = chunks(text, parts_count=3)
    for c in parts:
        await inject_user_text(page, c)
        await pace.beat(0.55)
    # Tiny extra pause so the (mocked) extraction REST call lands before
    # we move on to the agent reply.
    await pace.beat(0.6)


async def speak_agent(page: Page, text: str, pace: Pace) -> None:
    """Stream agent transcript chunks. The dock display switches from the
    user's transcript to the agent's the moment the first chunk arrives."""
    parts = chunks(text, parts_count=3)
    for c in parts:
        await inject_agent_text(page, c)
        await pace.beat(0.55)
    await pace.beat(0.4)


async def end_turn(page: Page, pace: Pace) -> None:
    await inject_turn_complete(page)
    await pace.medium()


# ---------------------------------------------------------------------------
# UI interactions.
# ---------------------------------------------------------------------------


async def start_listening(page: Page, pace: Pace) -> None:
    """Click the mic button and wait until the mock setup completes."""
    btn = page.get_by_role("button", name="Start recording")
    await btn.wait_for(state="visible")
    await btn.click()
    # Wait for the WS mock to be in the OPEN state (i.e. setupComplete sent).
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        ready = await page.evaluate("() => !!window.__lumenMockReady && window.__lumenMockReady()")
        if ready:
            break
        await asyncio.sleep(0.1)
    # The dock shows "Listening…" once live.ready flips true.
    try:
        await page.locator("text=Listening…").first.wait_for(timeout=4000)
    except Exception:
        pass
    await pace.short()


async def stop_listening(page: Page, pace: Pace) -> None:
    btn = page.get_by_role("button", name="Stop recording")
    if await btn.count():
        await btn.first.click()
        await pace.short()


async def toggle_extraction_mode(page: Page, mode: str, pace: Pace) -> None:
    label = "Granular" if mode == "granular" else "Wiki"
    await page.get_by_role("button", name=label).click()
    await pace.medium()


async def click_export(page: Page, pace: Pace) -> None:
    async with page.expect_download() as dl_info:
        await page.get_by_role("button", name="Export to Obsidian").click()
    download = await dl_info.value
    target = Path.cwd() / "demo-export" / download.suggested_filename
    target.parent.mkdir(exist_ok=True)
    await download.save_as(str(target))
    cue(f"Saved Obsidian vault to {target}", kind="ok")
    await pace.medium()


async def click_clear(page: Page, pace: Pace) -> None:
    page.once("dialog", lambda d: asyncio.create_task(d.accept()))
    await page.get_by_role("button", name="Clear journal").click()
    await pace.medium()


async def navigate_sidebar_to(page: Page, entity_name: str) -> bool:
    aside = page.locator("aside").first
    btn = aside.get_by_role("button", name=entity_name, exact=True)
    if await btn.count() == 0:
        return False
    await btn.first.click()
    return True


# ---------------------------------------------------------------------------
# Network interception for the graph-extraction REST call.
# ---------------------------------------------------------------------------


class MockState:
    def __init__(self, scripted: list[dict[str, Any]], granular_demo: dict[str, Any]) -> None:
        self.scripted = list(scripted)
        self.granular_demo = granular_demo
        self.use_granular_demo = False

    @staticmethod
    def is_granular_request(body: str) -> bool:
        return "silent graph extractor for a voice journal" in body


async def install_gemini_rest_mock(page: Page, mock: MockState) -> None:
    async def handler(route: Route) -> None:
        body = route.request.post_data or ""
        granular_mode = mock.is_granular_request(body)
        if mock.use_granular_demo:
            mock.use_granular_demo = False
            t = mock.granular_demo
            ents = list(t["wiki_entities"])
            rels = list(t["wiki_relations"])
            if granular_mode:
                ents += list(t["granular_extras_entities"])
                rels += list(t["granular_extras_relations"])
            payload = gemini_function_call_response(ents, rels)
        elif mock.scripted:
            t = mock.scripted.pop(0)
            payload = gemini_function_call_response(t["entities"], t["relations"])
        else:
            payload = gemini_function_call_response([], [])
        await route.fulfill(
            status=200,
            content_type="application/json",
            body=json.dumps(payload),
        )

    await page.route(
        "**/generativelanguage.googleapis.com/**:generateContent**",
        handler,
    )


# ---------------------------------------------------------------------------
# Demo flow.
# ---------------------------------------------------------------------------


def parse_viewport(spec: str) -> tuple[int, int]:
    try:
        w, h = spec.lower().split("x")
        return int(w), int(h)
    except Exception:
        raise SystemExit(f"--viewport must look like 1280x720, got {spec!r}")


async def run_demo(args: argparse.Namespace) -> int:
    project_dir = Path(__file__).resolve().parent.parent
    url = args.url.rstrip("/")
    host = url.split("://", 1)[1].split("/", 1)[0].split(":")[0]
    port = int(url.rsplit(":", 1)[-1]) if ":" in url.split("://", 1)[1] else 80
    vw, vh = parse_viewport(args.viewport)

    server_proc: subprocess.Popen[bytes] | None = None
    started_server = False

    try:
        if not args.no_server and not port_open(host, port):
            server_proc = start_dev_server(project_dir)
            started_server = True
            if not wait_for_port(host, port, timeout=90.0):
                cue(f"Dev server did not come up on {host}:{port} within 90s.", kind="warn")
                return 2
            cue(f"Dev server up on {host}:{port}", kind="ok")
        elif port_open(host, port):
            cue(f"Reusing dev server already on {host}:{port}", kind="ok")
        else:
            cue(f"Pass --no-server only if {host}:{port} is already serving.", kind="warn")
            return 2

        pace = Pace(args.speed)
        mock = MockState(TURNS, GRANULAR_DEMO)

        async with async_playwright() as pw:
            launch_args = [
                f"--window-size={vw},{vh + 84}",
                "--use-fake-ui-for-media-stream",
                "--use-fake-device-for-media-stream",
                "--autoplay-policy=no-user-gesture-required",
            ]
            browser = await pw.chromium.launch(headless=args.headless, args=launch_args)
            context = await browser.new_context(
                viewport={"width": vw, "height": vh},
                accept_downloads=True,
                device_scale_factor=2,
                permissions=["microphone"],
            )
            page = await context.new_page()

            # Order matters: install the boot script (WebSocket mock + overlays)
            # BEFORE any app JS runs, then the REST mock for graph extraction.
            await install_boot_script(page)
            await install_gemini_rest_mock(page, mock)

            # Wipe any previous run's localStorage so the graph starts clean.
            await page.add_init_script(
                "try { localStorage.removeItem('lumen.journal.v1'); "
                "localStorage.removeItem('lumen.extractionMode.v1'); } catch (e) {}"
            )

            banner("Lumen — automated voice-first demo")
            cue(f"Opening {url}  ({vw}x{vh} viewport)", kind="step")
            await page.goto(url, wait_until="domcontentloaded")
            await page.get_by_role("heading", name="Lumen").wait_for()

            # Wait for web fonts (Fraunces / Inter / JetBrains Mono) before the
            # title card paints; otherwise the opener flickers from Georgia
            # fallback into Fraunces on the first recorded frame.
            await wait_for_fonts(page)

            # Premium opener — paper-blurred title card, then mount the
            # persistent HUD chip so the viewer always knows this is scripted.
            await title_card(
                page,
                eyebrow="Demo · April 2026",
                title="Lumen",
                sub="A voice journal that quietly builds your personal wiki.",
                hold=1.9,
                pace=pace,
            )
            await mount_hud(page, "Demo · No mics · No APIs")
            await pace.short()

            # Mute the (silent) agent voice channel up-front so the muted glyph
            # shows in the dock — small visual nicety; no audio is generated
            # anyway because the mock WS never emits agent PCM frames.
            mute_btn = page.get_by_role("button", name="Mute agent voice")
            if await mute_btn.count():
                await mute_btn.first.click()
                await pace.short()

            cue("Tap the mic — Lumen connects and starts listening.", kind="step")
            await spotlight(page, "button[aria-label='Start recording']", "Tap to start the conversation")
            await pace.medium()
            await clear_spotlight(page)
            await start_listening(page, pace)
            cue("Voice channel open — mock setupComplete delivered.", kind="ok")
            await pace.medium()

            # ---- Three voice turns ----
            for i, turn in enumerate(TURNS, start=1):
                banner(f"Turn {i}/{len(TURNS)}")
                await set_chapter(
                    page,
                    f"{i:02d} / {len(TURNS):02d}",
                    turn.get("chapter", f"Turn {i}"),
                )
                cue(turn["narrate"], kind="step")
                await speak_user(page, turn["user_says"], pace)
                # Let the (mocked) extraction land and the sidebar auto-open
                # before Lumen replies.
                await pace.medium()
                await speak_agent(page, turn["agent_says"], pace)
                await end_turn(page, pace)

                # Sidebar showcase beats.
                aside_visible = await page.locator("aside").first.is_visible()
                if aside_visible:
                    for selector, caption in turn.get("sidebar_beats", []):
                        await spotlight(page, selector, caption)
                        await pace.dwell()
                    nav_target = turn.get("navigate_to")
                    if nav_target and await navigate_sidebar_to(page, nav_target):
                        cue(f"Sidebar navigated → {nav_target} (via inbound link)", kind="ok")
                        await pace.medium()
                        beat = turn.get("after_navigate_beat")
                        if beat:
                            await spotlight(page, beat[0], beat[1])
                            await pace.dwell()
                    await clear_spotlight(page)

            # ---- Wiki vs Granular comparison ----
            banner("Wiki vs Granular")
            await set_chapter(page, "Comparison", "Wiki vs Granular")
            cue("Switch extraction mode to Granular — every named thing becomes a node.", kind="step")
            await toggle_extraction_mode(page, "granular", pace)
            await spotlight(page, "div[aria-label='Extraction mode']", "Wiki ⇄ Granular")
            await pace.medium()
            await clear_spotlight(page)

            cue("Same kind of utterance, granular mode keeps the noise.", kind="step")
            mock.use_granular_demo = True
            await speak_user(page, GRANULAR_DEMO["user_says"], pace)
            await pace.medium()
            await speak_agent(page, GRANULAR_DEMO["agent_says_granular"], pace)
            await end_turn(page, pace)
            await pace.medium()

            cue("Flip back to Wiki — same utterance, but curated.", kind="step")
            await toggle_extraction_mode(page, "wiki", pace)
            mock.use_granular_demo = True
            await speak_user(
                page,
                "Quick second pass — meeting Sam at the library on Friday morning. Bass practice with Hadron after.",
                pace,
            )
            await pace.medium()
            await speak_agent(page, GRANULAR_DEMO["agent_says_wiki"], pace)
            await end_turn(page, pace)
            await pace.medium()

            # ---- Stop listening, export ----
            banner("Wrap up")
            await set_chapter(page, "Export", "Obsidian-ready vault")
            cue("Stop listening — clean state for the export shot.", kind="step")
            await stop_listening(page, pace)

            cue("Click the download icon — Lumen zips the whole vault.", kind="step")
            await spotlight(page, "button[aria-label='Export to Obsidian']", "Export the vault")
            await pace.medium()
            await clear_spotlight(page)
            await click_export(page, pace)

            if args.clear_at_end:
                banner("Clear the journal")
                cue("Reset the graph for the next take.", kind="step")
                await click_clear(page, pace)

            banner("Demo complete")
            cue("That's the full Lumen voice walkthrough.", kind="ok")

            # Curtain: clear the chapter chip + spotlight, then a quiet end
            # card that mirrors the opener's typography for symmetry.
            await clear_chapter(page)
            await clear_spotlight(page)
            await pace.short()
            await end_card(
                page,
                eyebrow="Lumen",
                title="Thanks for watching.",
                sub="Built with React, Gemini Live, and Tailwind.",
                meta="Trinab Goswamy · uWaterloo CS",
                hold=2.6,
                pace=pace,
            )

            if args.keep_open:
                cue("Keeping browser open — press Ctrl+C in this terminal to quit.", kind="info")
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    pass
            else:
                await pace.short()

            await context.close()
            await browser.close()

        return 0
    finally:
        if server_proc is not None and started_server:
            cue("Stopping dev server.", kind="info")
            server_proc.terminate()
            try:
                server_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server_proc.kill()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run a Lumen voice-first demo for screen recording.")
    p.add_argument("--url", default="http://localhost:8080", help="App URL.")
    p.add_argument("--no-server", action="store_true", help="Skip starting the dev server.")
    p.add_argument("--speed", type=float, default=1.0, help="Pause multiplier.")
    p.add_argument("--viewport", default="1280x720", help="Viewport WxH (default 1280x720).")
    p.add_argument("--headless", action="store_true", help="Run without a visible window.")
    p.add_argument("--keep-open", action="store_true", help="Leave browser open at the end.")
    p.add_argument(
        "--clear-at-end",
        action="store_true",
        help="Click the Clear-journal button as the last step.",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    try:
        return asyncio.run(run_demo(args))
    except KeyboardInterrupt:
        cue("Interrupted.", kind="warn")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

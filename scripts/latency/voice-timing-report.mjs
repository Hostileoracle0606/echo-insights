#!/usr/bin/env node
// Turns a device log from a real voice session into latency numbers.
//
//   flutter run --debug 2>&1 | tee session.log      # talk to Lumen for a few minutes
//   node scripts/latency/voice-timing-report.mjs session.log
//
// It reads the `[voice][area] @<ms> message` lines written by vlog
// (lib/logic/voice_log.dart) and reports, per metric, count / median / p95 /
// max in milliseconds:
//
//   reply_wait     last transcribed user words → first audio of Lumen's reply
//                  (includes Gemini's 700 ms end-of-speech silence)
//   tool:<name>    how long Lumen waited on each tool answer
//   connect        "connecting" → socket open → setup acknowledged
//   start:<stage>  the session-start stages the app already times
//   extract_*      per-turn retrieval, extraction model and commit times
import { readFileSync } from "node:fs";

const LINE = /\[voice\]\[(\w+)\] @(\d+) (.*)$/;

export function parse(text) {
  const metrics = new Map();
  const add = (name, ms) => {
    if (!Number.isFinite(ms)) return;
    if (!metrics.has(name)) metrics.set(name, []);
    metrics.get(name).push(ms);
  };
  let lastUserWords = null;
  let connectingAt = null;
  let socketOpenAt = null;
  for (const raw of text.split("\n")) {
    const m = LINE.exec(raw);
    if (!m) continue;
    const [, area, atText, message] = m;
    const at = Number(atText);
    if (area === "client") {
      if (message.startsWith("gemini → user transcript")) lastUserWords = at;
      else if (message === "gemini → reply audio starts") {
        if (lastUserWords !== null) add("reply_wait", at - lastUserWords);
        lastUserWords = null;
      } else if (message.startsWith("connecting (model=")) connectingAt = at;
      else if (message.startsWith("socket open")) {
        if (connectingAt !== null) add("connect:socket", at - connectingAt);
        socketOpenAt = at;
      }
      const tool = /^toolCall (\S+) (?:answered in|timed out after|failed after) (\d+)ms/.exec(message);
      if (tool) add(`tool:${tool[1]}${message.includes("timed out") ? " (timed out)" : ""}`, Number(tool[2]));
    } else if (area === "timing") {
      const stage = /^(.*?) \+(\d+)ms$/.exec(message);
      if (!stage) continue;
      const [, name, ms] = stage;
      if (name === "setup complete" && socketOpenAt !== null) add("connect:setup_ack", at - socketOpenAt);
      if (name.startsWith("extract retrieve")) add("extract_retrieve", Number(ms));
      else if (name.startsWith("extract model")) add("extract_retrieve+model", Number(ms));
      else if (name === "commit") add("extract_commit", Number(ms));
      else add(`start:${name}`, Number(ms));
    }
  }
  return metrics;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return NaN;
  return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
}

export function report(metrics) {
  const rows = [["metric", "n", "p50", "p95", "max"]];
  for (const [name, values] of [...metrics.entries()].sort()) {
    const s = [...values].sort((a, b) => a - b);
    rows.push([name, String(s.length), String(percentile(s, 0.5)), String(percentile(s, 0.95)), String(s.at(-1))]);
  }
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  return rows.map((r) => r.map((c, i) => (i === 0 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join("  ")).join("\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const file = process.argv[2];
  if (!file) {
    console.error("usage: node scripts/latency/voice-timing-report.mjs <flutter-run.log>");
    process.exit(2);
  }
  const metrics = parse(readFileSync(file, "utf8"));
  if (metrics.size === 0) {
    console.error("No timestamped [voice] lines found. Run a debug build from this branch or later.");
    process.exit(1);
  }
  console.log(report(metrics));
}

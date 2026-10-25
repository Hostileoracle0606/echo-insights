// Run: node --test scripts/latency/voice-timing-report.test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { parse } from "./voice-timing-report.mjs";

// A synthetic log in the exact vlog format; the numbers are made up.
const sample = `
flutter: [voice][client] @1000 connecting (model=gemini-3.1-flash-live-preview)…
flutter: [voice][client] @1180 socket open — sending setup
flutter: [voice][timing] @1450 setup complete +900ms
flutter: [voice][client] @5000 gemini → user transcript (+12 chars)
flutter: [voice][client] @5400 gemini → user transcript (+20 chars)
flutter: [voice][client] @5600 toolCall: get_relevant_memory
flutter: [voice][client] @6200 toolCall get_relevant_memory answered in 600ms
flutter: [voice][client] @6800 gemini → reply audio starts
flutter: [voice][client] @9000 gemini → turnComplete
flutter: [voice][timing] @9100 extract retrieve +320ms
flutter: [voice][timing] @9900 extract model +1120ms
flutter: [voice][timing] @9950 commit +60ms
flutter: [voice][client] @12000 gemini → user transcript (+30 chars)
flutter: [voice][client] @13100 gemini → reply audio starts
`;

test("derives reply wait, tool, connect and extraction timings", () => {
  const m = parse(sample);
  assert.deepEqual(m.get("reply_wait"), [1400, 1100]);
  assert.deepEqual(m.get("tool:get_relevant_memory"), [600]);
  assert.deepEqual(m.get("connect:socket"), [180]);
  assert.deepEqual(m.get("connect:setup_ack"), [270]);
  assert.deepEqual(m.get("extract_retrieve"), [320]);
  assert.deepEqual(m.get("extract_retrieve+model"), [1120]);
  assert.deepEqual(m.get("extract_commit"), [60]);
  assert.deepEqual(m.get("start:setup complete"), [900]);
});

test("ignores lines without the @ms stamp (older builds)", () => {
  assert.equal(parse("[voice][client] gemini → reply audio starts").size, 0);
});

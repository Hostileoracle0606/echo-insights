// One cold launch on a simulator: launch the app, keep its `[lumen-timing]`
// lines from the unified log for a fixed window, and add a host-side span
// from the launch command to the arrival of first_frame (the in-app clock
// starts at Dart main(), so it cannot see native/engine start-up).
//
//   node eval/timing/capture.mjs <device> <bundle-id> <seconds> <out.jsonl>
import { execFile, spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { PREFIX } from './parse.mjs';

/** @param {{text: string, at: number}[]} lines host-timestamped log lines */
export function annotate(lines, { launchedAt }) {
  const out = [];
  let mode;
  let firstFrameAt;
  for (const { text, at } of lines) {
    const i = text.indexOf(PREFIX);
    if (i < 0) continue;
    const line = text.slice(i).trim();
    out.push(line);
    try {
      const mark = JSON.parse(line.slice(PREFIX.length));
      mode ??= mark.mode;
      if (mark.stage === 'first_frame' && firstFrameAt === undefined) firstFrameAt = at;
    } catch {
      // parseRun counts it as rejected
    }
  }
  if (firstFrameAt !== undefined) {
    const ms = Math.round(firstFrameAt - launchedAt);
    out.push(`${PREFIX} ${JSON.stringify({ v: 1, stage: 'launch_to_first_frame_host', phase: 'span', t_ms: ms, dur_ms: ms, mode })}`);
  }
  return out.length ? `${out.join('\n')}\n` : '';
}

/** "2026-11-18 16:13:36.054321-0800" (unified log) → epoch ms; NaN if not one. */
export function logTime(ts) {
  const m = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\.(\d{3})\d*([+-])(\d{2})(\d{2})$/.exec(ts ?? '');
  if (!m) return NaN;
  return Date.parse(`${m[1]}T${m[2]}.${m[3]}${m[4]}${m[5]}:${m[6]}`);
}

/** `log stream --style ndjson` output → [{text, at}] (non-JSON lines skipped). */
export function fromLogStream(text) {
  const out = [];
  for (const raw of text.split('\n')) {
    if (!raw.startsWith('{')) continue;
    try {
      const event = JSON.parse(raw);
      if (typeof event.eventMessage === 'string') out.push({ text: event.eventMessage, at: logTime(event.timestamp) });
    } catch {
      // a partial line at the cut-off
    }
  }
  return out;
}

// Flutter's print reaches the simulator's unified log (`flutter: …`), not the
// `simctl launch --console` streams, so the run is read from `log stream`.
// Both the launch time and the log timestamps are this Mac's clock.
function capture(device, bundleId, seconds, outPath) {
  return new Promise((resolve, reject) => {
    const stream = spawn('xcrun', ['simctl', 'spawn', device, 'log', 'stream', '--style', 'ndjson', '--level', 'debug',
      '--predicate', `process == "Runner" AND eventMessage CONTAINS "${PREFIX}"`], { stdio: ['ignore', 'pipe', 'ignore'] });
    let text = '';
    stream.stdout.on('data', (chunk) => { text += chunk.toString(); });
    // Give the stream a moment to attach before the launch.
    setTimeout(() => {
      const launchedAt = Date.now();
      execFile('xcrun', ['simctl', 'launch', device, bundleId], (error) => {
        if (error) {
          stream.kill('SIGTERM');
          reject(error);
        }
      });
      setTimeout(() => {
        stream.kill('SIGTERM');
        writeFileSync(outPath, annotate(fromLogStream(text), { launchedAt }));
        resolve();
      }, seconds * 1000);
    }, 1500);
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const [device, bundleId, seconds, outPath] = process.argv.slice(2);
  if (!outPath) {
    console.error('usage: capture.mjs <device> <bundle-id> <seconds> <out.jsonl>');
    process.exit(2);
  }
  await capture(device, bundleId, Number(seconds), outPath);
}

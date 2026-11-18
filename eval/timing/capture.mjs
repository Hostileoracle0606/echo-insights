// One cold launch on a simulator: spawn `simctl launch --console-pty`, keep
// the `[lumen-timing]` lines for a fixed window, and add a host-side span
// from the launch command to the arrival of first_frame (the in-app clock
// starts at Dart main(), so it cannot see native/engine start-up).
//
//   node eval/timing/capture.mjs <device> <bundle-id> <seconds> <out.jsonl>
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
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

function capture(device, bundleId, seconds, outPath) {
  return new Promise((resolve) => {
    const lines = [];
    const launchedAt = performance.now();
    const child = spawn('xcrun', ['simctl', 'launch', '--console-pty', device, bundleId], { stdio: ['ignore', 'pipe', 'pipe'] });
    let buffer = '';
    const onData = (chunk) => {
      const at = performance.now();
      buffer += chunk.toString();
      const parts = buffer.split(/\r?\n/);
      buffer = parts.pop();
      for (const text of parts) lines.push({ text, at });
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    setTimeout(() => {
      child.kill('SIGTERM');
      if (buffer) lines.push({ text: buffer, at: performance.now() });
      writeFileSync(outPath, annotate(lines, { launchedAt }));
      resolve(lines.length);
    }, seconds * 1000);
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

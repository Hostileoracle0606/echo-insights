// node --test entry for scenarios.test.ts, which needs vite-node (it imports
// the app's TypeScript turn pipeline through the `@/` alias).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');

test('scenario tests (vite-node)', () => {
  const run = spawnSync(
    resolve(root, 'node_modules/.bin/vite-node'),
    ['--config', 'eval/recovery/vite.config.ts', 'eval/recovery/scenarios.test.ts'],
    { cwd: root, encoding: 'utf8', timeout: 120_000 },
  );
  const output = `${run.stdout}\n${run.stderr}`;
  assert.equal(run.status, 0, output);
  assert.match(output, /# fail 0/, output);
});

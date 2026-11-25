import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { newestRunFile } from './results.mjs';

function put(root, dir, rel, mtimeSeconds) {
  const path = join(root, dir, 'memory', rel);
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, '{}');
  utimesSync(path, mtimeSeconds, mtimeSeconds);
  return path;
}

test('newestRunFile: the same day sorts by write time, not by commit sha', () => {
  const root = mkdtempSync(join(tmpdir(), 'memory-results-'));
  put(root, '2026-11-18-f4e7de1', 'briefs/x.json', 1_000);
  const newer = put(root, '2026-11-18-9a89931', 'briefs/x.json', 2_000);
  assert.equal(newestRunFile(root, 'briefs/x.json'), newer);
});

test('newestRunFile: a later day wins over an earlier day written later', () => {
  const root = mkdtempSync(join(tmpdir(), 'memory-results-'));
  const later = put(root, '2026-11-19-aaaaaaa', 'graphs/x.json', 1_000);
  put(root, '2026-11-18-bbbbbbb', 'graphs/x.json', 9_000);
  assert.equal(newestRunFile(root, 'graphs/x.json'), later);
  assert.equal(newestRunFile(root, 'graphs/missing.json'), null);
  assert.equal(newestRunFile(join(root, 'nope'), 'graphs/x.json'), null);
});

test('newestRunFile: an optional predicate skips files that do not qualify', () => {
  const root = mkdtempSync(join(tmpdir(), 'memory-results-'));
  const older = put(root, '2026-11-18-aaaaaaa', 'extract-log.json', 1_000);
  put(root, '2026-11-18-bbbbbbb', 'extract-log.json', 2_000);
  assert.equal(newestRunFile(root, 'extract-log.json', (path) => path === older), older);
});

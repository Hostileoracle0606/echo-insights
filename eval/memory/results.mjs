// Finds the newest saved file of one kind across run directories
// (eval/results/<YYYY-MM-DD>-<sha>/memory/...), so a run resumes whatever
// commit it is on. Days sort by date; within a day, by when the file was
// written (the sha in the name says nothing about order).
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** accept(path): optional filter, e.g. a log that mentions a given scenario. */
export function newestRunFile(resultsRoot, rel, accept = () => true) {
  if (!existsSync(resultsRoot)) return null;
  const found = readdirSync(resultsRoot)
    .filter((d) => /^\d{4}-\d{2}-\d{2}-/.test(d))
    .map((d) => ({ day: d.slice(0, 10), path: join(resultsRoot, d, 'memory', rel) }))
    .filter((c) => existsSync(c.path) && accept(c.path))
    .map((c) => ({ ...c, mtime: statSync(c.path).mtimeMs }))
    .sort((a, b) => (a.day === b.day ? b.mtime - a.mtime : a.day < b.day ? 1 : -1));
  return found[0]?.path ?? null;
}

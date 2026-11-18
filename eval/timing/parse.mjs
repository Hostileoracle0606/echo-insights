// Picks `[lumen-timing]` lines out of a captured log (simulator console,
// device log export, or the Node retrieval runner) and validates them.
// Content-free by construction: the only string values a mark may carry are
// its stage, phase and build mode.

export const PREFIX = '[lumen-timing]';
const STRING_KEYS = new Set(['stage', 'phase', 'mode']);
const PHASES = new Set(['mark', 'begin', 'end', 'span']);

function valid(mark) {
  if (!mark || typeof mark !== 'object' || Array.isArray(mark)) return false;
  if (typeof mark.stage !== 'string' || !mark.stage) return false;
  if (!PHASES.has(mark.phase)) return false;
  if (typeof mark.t_ms !== 'number') return false;
  for (const [key, value] of Object.entries(mark)) {
    if (STRING_KEYS.has(key)) continue;
    if (typeof value !== 'number' && typeof value !== 'boolean') return false;
  }
  return true;
}

/**
 * @param {string} text a whole captured log
 * @param {{allowDebug?: boolean}} [options] debug builds are several times
 *   slower; their marks are refused unless the caller labels them on purpose.
 * @returns {{marks: object[], rejected: number}}
 */
export function parseRun(text, { allowDebug = false } = {}) {
  const marks = [];
  let rejected = 0;
  for (const raw of text.split(/\r?\n/)) {
    const at = raw.indexOf(PREFIX);
    if (at < 0) continue;
    let mark;
    try {
      mark = JSON.parse(raw.slice(at + PREFIX.length).trim());
    } catch {
      rejected += 1;
      continue;
    }
    if (!valid(mark)) {
      rejected += 1;
      continue;
    }
    marks.push(mark);
  }
  const modes = new Set(marks.map((m) => m.mode));
  if (modes.size > 1) throw new Error(`run mixes build modes: ${[...modes].join(', ')}`);
  if (modes.has('debug') && !allowDebug) {
    throw new Error('run was built in debug mode; pass allowDebug to label it as such');
  }
  return { marks, rejected };
}

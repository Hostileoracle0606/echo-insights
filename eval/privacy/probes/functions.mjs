// Auth probes for the Supabase edge functions, served locally.
import { cell } from '../report.mjs';
import { findLeaks, newCanary } from '../canary.mjs';

// spends: a valid caller would reach a paid provider, so only invalid
// credentials are sent (deleted_user stays: its token still verifies).
export const FUNCTION_TARGETS = Object.freeze([
  { name: 'retrieve-memory', spends: false },
  { name: 'speak-agent', spends: true },
  { name: 'extract-graph', spends: true },
  { name: 'embed-entities', internal: true },
]);

const SPENDING_SKIP = new Set(['owner', 'other_user']);

export function classifyFunction({ status, text, canaries }) {
  if (findLeaks([text], canaries).length) return 'leak';
  if (status >= 500 || status === 0) return 'error';
  if (status >= 400) return 'deny';
  return 'allow';
}

async function send(fetchImpl, url, headers, body) {
  try {
    const response = await fetchImpl(url, {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(20_000),
    });
    const text = await response.text();
    return { status: response.status, text: `${JSON.stringify([...response.headers])}\n${text}` };
  } catch {
    return { status: 0, text: '' };
  }
}

export async function probeFunctions({
  url, kinds, headersByKind, notebookId, canaries, internalSecret,
  targets = FUNCTION_TARGETS.map((t) => t.name), fetchImpl = fetch,
}) {
  const cells = [];
  for (const target of FUNCTION_TARGETS.filter((t) => targets.includes(t.name))) {
    const endpoint = `${url}/functions/v1/${target.name}`;
    const probe = async (credential, operation, headers, body, expected) => {
      const requestCanary = newCanary('request');
      const result = await send(fetchImpl, endpoint, headers, { ...body, query: requestCanary, text: requestCanary });
      // The owner's own request echoed back to the owner is not a cross-account leak.
      const watched = credential === 'owner' ? canaries : [...canaries, requestCanary];
      cells.push(cell({
        surface: 'function', target: target.name, credential, operation, expected,
        observed: classifyFunction({ status: result.status, text: result.text, canaries: watched }),
      }));
    };

    if (target.internal) {
      for (const kind of kinds) {
        await probe(kind, 'invoke', headersByKind[kind], { notebookId }, 'deny');
      }
      await probe('wrong_secret', 'invoke',
        { 'x-internal-secret': `${internalSecret}-wrong` }, { notebookId }, 'deny');
      continue;
    }

    for (const kind of kinds) {
      if (target.spends && SPENDING_SKIP.has(kind)) continue;
      const expected = kind === 'owner' ? 'allow' : 'deny';
      if (target.name === 'retrieve-memory') {
        for (const scope of ['notebook', 'user']) {
          await probe(kind, `scope:${scope}`, headersByKind[kind], { notebookId, scope }, expected);
        }
      } else {
        await probe(kind, 'invoke', headersByKind[kind], { notebookId }, expected);
      }
    }
  }
  return cells;
}

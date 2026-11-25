// Auth probes for the Supabase edge functions, served locally. Each function
// has a positive control that cannot spend provider quota; if it fails, that
// function's denials prove nothing and are reported as inconclusive.
import { randomUUID } from 'node:crypto';
import { cell } from '../report.mjs';
import { findLeaks, newCanary } from '../canary.mjs';

export const FUNCTION_TARGETS = Object.freeze([
  { name: 'retrieve-memory' },
  { name: 'speak-agent', userScoped: true },
  // extract-graph (legacy Groq edge function) was removed by LM-118; extraction
  // is the AWS Lambda, probed in-process by probes/lambdas.mjs.
  { name: 'embed-entities', internal: true },
]);

export function classifyFunction({ status, text, canaries }) {
  if (findLeaks([text], canaries).length) return 'leak';
  if (status === 401 || status === 403) return 'deny';
  if (status === 404) return /notebook not found/.test(text) ? 'deny' : 'error';
  if (status >= 200 && status < 300) return 'allow';
  // Past the auth preamble, a provider key the local env deliberately lacks.
  if (status === 501 && /not configured/.test(text)) return 'allow';
  return 'error';
}

async function send(fetchImpl, url, headers, body) {
  try {
    const response = await fetchImpl(url, {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(60_000), // a cold local edge runtime loads gte-small on first use (~30 s),
    });
    const text = await response.text();
    return { status: response.status, text: `${JSON.stringify([...response.headers])}\n${text}` };
  } catch {
    return { status: 0, text: '' };
  }
}

export async function probeFunctions({
  url, kinds, headersByKind, notebookId, canaries, internalSecret, ownerQueryText, ownerMarkers = [],
  targets = FUNCTION_TARGETS.map((t) => t.name), fetchImpl = fetch,
}) {
  const cells = [];
  for (const target of FUNCTION_TARGETS.filter((t) => targets.includes(t.name))) {
    const endpoint = `${url}/functions/v1/${target.name}`;
    const own = [];
    const probe = async ({ credential, operation, headers, body, expected, control = false, judge }) => {
      const requestCanary = newCanary('request');
      const result = await send(fetchImpl, endpoint, headers, { text: requestCanary, query: requestCanary, ...body });
      // Every planted canary is A's own data, so nothing the owner receives can leak.
      const watched = credential === 'owner' ? [] : [...canaries, requestCanary];
      const observed = judge ? judge(result, watched) : classifyFunction({ ...result, canaries: watched });
      own.push(cell({ surface: 'function', target: target.name, credential, operation, expected, observed, control }));
    };

    if (target.internal) {
      for (const kind of kinds) {
        await probe({ credential: kind, operation: 'invoke', headers: headersByKind[kind], body: { notebookId }, expected: 'deny' });
      }
      await probe({ credential: 'wrong_secret', operation: 'invoke', headers: { 'x-internal-secret': `${internalSecret}-wrong` }, body: { notebookId }, expected: 'deny' });
      await probe({ credential: 'internal_secret', operation: 'invoke', headers: { 'x-internal-secret': internalSecret }, body: { notebookId }, expected: 'allow', control: true });
    } else {
      for (const kind of kinds) {
        const headers = headersByKind[kind];
        const owner = kind === 'owner';
        const expected = owner || (target.userScoped && kind === 'other_user') ? 'allow' : 'deny';
        if (target.name === 'retrieve-memory') {
          for (const scope of ['notebook', 'user']) {
            const control = owner && scope === 'user';
            await probe({
              credential: kind, operation: `scope:${scope}`, headers, expected, control,
              body: { notebookId, scope, ...(owner ? { query: ownerQueryText } : {}) },
              // The owner must get A's memory back, not merely a 200.
              judge: control ? (result, watched) => {
                const observed = classifyFunction({ ...result, canaries: watched });
                return observed === 'allow' && !ownerMarkers.some((m) => result.text.includes(m)) ? 'error' : observed;
              } : undefined,
            });
          }
        } else {
          await probe({ credential: kind, operation: 'invoke', headers, expected, control: owner, body: { notebookId } });
        }
      }
    }

    const controlled = own.filter((c) => c.control).every((c) => c.pass);
    for (const c of own) {
      cells.push(!controlled && !c.control && c.observed === 'deny' ? { ...c, observed: 'error', pass: c.expected === 'error' } : c);
    }
  }
  return cells;
}

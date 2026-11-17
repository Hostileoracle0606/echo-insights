// The AWS Lambdas, run in-process exactly as API Gateway composes them:
// authorizer first, handler only on isAuthorized. Supabase calls are real
// (local stack); every other host is a counting stub, so no provider is paid.
import { createSupabaseAuthorizer } from '../../../infra/lambda/supabase-authorizer/core.mjs';
import { createLiveSessionHandler } from '../../../infra/lambda/live-session/core.mjs';
import { createExtractGraphHandler } from '../../../infra/lambda/extract-graph/core.mjs';
import { createCloseSessionHandler } from '../../../infra/lambda/close-session/core.mjs';
import { createSessionBriefHandler } from '../../../infra/lambda/close-session/brief.mjs';
import { cell } from '../report.mjs';
import { findLeaks } from '../canary.mjs';

const noSleep = async () => {};

export const LAMBDA_ROUTES = Object.freeze([
  { name: 'live-sessions', notebook: false, create: (d) => createLiveSessionHandler(d) },
  { name: 'notebook-live-sessions', notebook: true, create: (d) => createLiveSessionHandler(d) },
  {
    name: 'extractions', notebook: true,
    create: (d) => createExtractGraphHandler({ ...d, ...memoryClaimStore(), sleep: noSleep }),
    body: (canary) => ({
      turnId: 'privacy-matrix-turn', extractorVersion: 'privacy-matrix/v1', mode: 'granular',
      text: `I talked about ${canary} today.`,
      context: { entities: [], relations: [], recentConversation: [] },
    }),
  },
  { name: 'close', notebook: true, create: (d) => createCloseSessionHandler({ ...d, sleep: noSleep }) },
  { name: 'brief', notebook: true, create: (d) => createSessionBriefHandler({ ...d, sleep: noSleep }) },
]);

export function recordingFetch({ supabaseUrl, realFetch = fetch, providerResponder }) {
  const origin = new URL(supabaseUrl).origin;
  let calls = 0;
  const fetchImpl = async (url, init) => {
    if (new URL(String(url)).origin === origin) return realFetch(url, init);
    calls += 1;
    return providerResponder(String(url), init);
  };
  return { fetchImpl, providerCalls: () => calls };
}

// Fake Gemini: a live auth token for the broker, unavailable for everything else.
export function fakeProvider(url) {
  if (url.endsWith('/auth_tokens')) {
    return new Response(JSON.stringify({ name: 'auth_tokens/privacy-matrix-ephemeral' }), { status: 200 });
  }
  return new Response('{"error":{"code":503}}', { status: 503 });
}

// Same contract as the DynamoDB store in infra/lambda/extract-graph/index.mjs.
export function memoryClaimStore() {
  const records = new Map();
  const observed = (record, inputHash, now) => {
    if (record.inputHash !== inputHash) return { status: 'mismatch' };
    if (record.status === 'completed') return { status: 'completed', patch: record.patch };
    return { status: 'pending', retryAfterMs: Math.max(250, Math.min(2_000, record.leaseExpiresAt - now)) };
  };
  return {
    async acquireExtraction({ id, inputHash, ownerToken, now, leaseExpiresAt }) {
      const record = records.get(id);
      const expiredLease = record?.status === 'pending' && record.inputHash === inputHash &&
        record.leaseExpiresAt <= now;
      if (!record || expiredLease) {
        records.set(id, { status: 'pending', inputHash, ownerToken, leaseExpiresAt });
        return { status: 'acquired' };
      }
      return observed(record, inputHash, now);
    },
    async completeExtraction({ id, inputHash, ownerToken, patch }) {
      const record = records.get(id);
      if (record?.status === 'pending' && record.inputHash === inputHash && record.ownerToken === ownerToken) {
        records.set(id, { status: 'completed', inputHash, patch });
        return { status: 'completed', patch };
      }
      return observed(record, inputHash, Date.now());
    },
  };
}

export async function gatewayInvoke({ authorize, handler, event }) {
  const decision = await authorize(event);
  if (!decision.isAuthorized) return { statusCode: 403, body: '{"message":"Forbidden"}', headers: {} };
  return handler({
    ...event,
    requestContext: { ...event.requestContext, authorizer: { lambda: decision.context } },
  });
}

// Reaching the provider counts as being let in, whatever status came back:
// for a bad credential that is quota spent on someone else's behalf.
export function classifyLambda({ statusCode, text, spent, canaries }) {
  if (findLeaks([text], canaries).length) return 'leak';
  return spent > 0 || statusCode < 300 ? 'allow' : 'deny';
}

async function capturingConsole(logs, run) {
  const methods = ['log', 'info', 'warn', 'error', 'debug'];
  const original = Object.fromEntries(methods.map((m) => [m, console[m]]));
  for (const m of methods) console[m] = (...args) => logs.push(args.map(String).join(' '));
  try {
    return await run();
  } finally {
    Object.assign(console, original);
  }
}

export async function probeLambdas({
  url, anonKey, kinds, headersByKind, notebookId, canaries, permanentKey, entityCanary,
  realFetch = fetch, routes = LAMBDA_ROUTES,
}) {
  const cells = [];
  const logs = [];
  const watched = [...canaries, permanentKey];
  for (const route of routes) {
    for (const kind of kinds) {
      const { fetchImpl, providerCalls } = recordingFetch({ supabaseUrl: url, realFetch, providerResponder: fakeProvider });
      const deps = { supabaseUrl: url, publishableKey: anonKey, fetchImpl, getPermanentCredential: async () => permanentKey };
      const authorize = createSupabaseAuthorizer(deps);
      const event = {
        headers: { ...headersByKind[kind] },
        pathParameters: route.notebook ? { notebookId } : undefined,
        requestContext: {},
        body: route.body ? JSON.stringify(route.body(entityCanary)) : null,
      };
      let result;
      try {
        result = await capturingConsole(logs, () => gatewayInvoke({ authorize, handler: route.create(deps), event }));
      } catch {
        result = { statusCode: 0, body: '' };
      }
      const text = `${JSON.stringify(result.headers ?? {})}\n${result.body ?? ''}`;
      // The owner sending its own text is not a leak; the permanent key always is.
      const leakSet = kind === 'owner' ? [...canaries.filter((c) => c !== entityCanary), permanentKey] : watched;
      cells.push(cell({
        surface: 'lambda', target: route.name, credential: kind, operation: 'invoke',
        expected: kind === 'owner' ? 'allow' : 'deny',
        observed: result.statusCode === 0 ? 'error'
          : classifyLambda({ statusCode: result.statusCode, text, spent: providerCalls(), canaries: leakSet }),
      }));
      if (kind === 'owner' && route.name === 'live-sessions') {
        let token = null;
        try { token = JSON.parse(result.body).sessionToken ?? null; } catch { /* non-JSON */ }
        const exposed = findLeaks([text], [permanentKey]).length > 0 || token === permanentKey;
        cells.push(cell({
          surface: 'lambda', target: route.name, credential: kind, operation: 'secret_off_client',
          expected: 'no_leak', observed: token && !exposed ? 'no_leak' : exposed ? 'leak' : 'error',
        }));
      }
    }
  }
  return { cells, logs };
}

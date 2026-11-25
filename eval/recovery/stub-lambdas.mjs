// The API Gateway routes the apps call, run in-process exactly as deployed
// (authorizer first, then the handler), against local Supabase, with the
// model answered by a stub. Shared by the fault matrix (run.ts) and the host
// gateway the simulator kill test talks to (gateway-server.mjs).
//
// Zero spend: the handlers' fetch sends Supabase-origin requests to the local
// stack and everything else to the stub; a guard under it counts (and
// refuses) any request that would leave the machine. `realCalls()` must be 0.
import { readFileSync } from 'node:fs';
import { createSupabaseAuthorizer } from '../../infra/lambda/supabase-authorizer/core.mjs';
import { createExtractGraphHandler } from '../../infra/lambda/extract-graph/core.mjs';
import { createSessionBriefHandler } from '../../infra/lambda/close-session/brief.mjs';
import { gatewayInvoke, memoryClaimStore, recordingFetch } from '../privacy/probes/lambdas.mjs';

export const fixtures = JSON.parse(readFileSync(new URL('./fixtures/patches.json', import.meta.url), 'utf8'));
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);
const noSleep = async () => {};

const json = (value) => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } });
const call = (name, args) => json({ candidates: [{ content: { parts: [{ functionCall: { name, args } }] } }] });

// A turn is recognised by a phrase that holds no name, so it still matches
// after the iOS app swaps names for stand-ins before extraction. Only the
// prompt's NEW UTTERANCE section counts: the recent conversation before it
// carries earlier turns' text.
export function turnFor(body) {
  const at = body.lastIndexOf('NEW UTTERANCE:');
  const current = at >= 0 ? body.slice(at) : body;
  return Object.values(fixtures.turns).find((t) => current.includes(t.key));
}

export function createStubbedLambdas({ url, anonKey, realFetch = fetch }) {
  let realCalls = 0;
  const extractCalls = new Map();
  const guarded = async (input, init) => {
    if (!LOOPBACK.has(new URL(String(input)).hostname)) {
      realCalls += 1;
      throw new TypeError('recovery eval: request to a non-local host refused');
    }
    return realFetch(input, init);
  };

  function stubProvider(target, init) {
    const body = String(init?.body ?? '');
    if (target.includes('-tts:')) {
      const data = Buffer.alloc(4800).toString('base64'); // 0.1 s of PCM16 silence
      return json({ candidates: [{ content: { parts: [{ inlineData: { mimeType: 'audio/L16;codec=pcm;rate=24000', data } }] } }] });
    }
    if (body.includes('write_session_brief')) return call('write_session_brief', fixtures.brief);
    const turn = turnFor(body);
    if (!turn) return new Response('{"error":{"code":503}}', { status: 503 });
    extractCalls.set(turn.text, (extractCalls.get(turn.text) ?? 0) + 1);
    return call('extract_graph', { supersedes: [], ...turn.patch });
  }

  const lambdaFetch = recordingFetch({ supabaseUrl: url, realFetch: guarded, providerResponder: stubProvider });
  const deps = {
    supabaseUrl: url,
    publishableKey: anonKey,
    fetchImpl: lambdaFetch.fetchImpl,
    getPermanentCredential: async () => 'recovery-eval-stub-credential',
  };
  const authorize = createSupabaseAuthorizer(deps);
  // One claim store per process: it stands in for DynamoDB, which outlives
  // any client.
  const handlers = {
    extractions: createExtractGraphHandler({ ...deps, ...memoryClaimStore(), sleep: noSleep }),
    brief: createSessionBriefHandler({ ...deps, sleep: noSleep, log: () => {} }),
  };

  return {
    guardedFetch: guarded,
    routes: Object.keys(handlers),
    async gateway(route, event) {
      const handler = handlers[route];
      if (!handler) return { statusCode: 404, body: '{"message":"Not Found"}' };
      return gatewayInvoke({ authorize, handler, event });
    },
    providerCalls: () => ({ real: realCalls, stub: lambdaFetch.providerCalls() }),
    extractCalls: (text) => extractCalls.get(text) ?? 0,
  };
}

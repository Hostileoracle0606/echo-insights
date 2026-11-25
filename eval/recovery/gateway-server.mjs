// The API Gateway, on this Mac, for the simulator kill test: the app is built
// with NOTEBOOK_RUNTIME_URL=http://127.0.0.1:$RECOVERY_GATEWAY_PORT and its
// extraction requests reach the real Lambda here (stubbed model, local
// Supabase). Logs one line per request so kill.sh can time a kill from the
// moment extraction begins; ids only, never text.
//   source eval/privacy/local-env.sh && node eval/recovery/gateway-server.mjs
import { createServer } from 'node:http';
import { localStack } from './local.mjs';
import { createStubbedLambdas } from './stub-lambdas.mjs';

const stack = localStack(process.env);
if (!stack) {
  console.error('gateway: source eval/privacy/local-env.sh first');
  process.exit(2);
}
const port = Number(process.env.RECOVERY_GATEWAY_PORT ?? 55399);
// Holds every extraction response this long, so a kill timed from "begin"
// can land inside extraction rather than always after the commit.
const holdMs = Number(process.env.RECOVERY_GATEWAY_HOLD_MS ?? 0);
const lambdas = createStubbedLambdas({ url: stack.url, anonKey: stack.anonKey });
const log = (line) => process.stdout.write(`[gateway] ${new Date().toISOString()} ${line}\n`);
const quietConsole = () => { console.log = console.info = console.warn = () => {}; };
const say = console.log.bind(console);
quietConsole();

const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString('utf8');
  const parts = new URL(req.url, 'http://gateway').pathname.split('/').filter(Boolean); // v1 notebooks {id} {route}
  const notebookId = parts[1] === 'notebooks' ? parts[2] : undefined;
  const route = notebookId ? parts[3] : parts[1];
  log(`${route ?? '?'} begin notebook=${notebookId ?? '-'}`);
  let result;
  try {
    result = await lambdas.gateway(route, {
      headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k.toLowerCase(), String(v)])),
      pathParameters: notebookId ? { notebookId } : undefined,
      requestContext: {},
      body,
    });
  } catch {
    result = { statusCode: 503, body: '{"status":"rejected","code":"providerUnavailable"}' };
  }
  if (route === 'extractions' && holdMs > 0) await new Promise((r) => setTimeout(r, holdMs));
  log(`${route ?? '?'} end notebook=${notebookId ?? '-'} status=${result.statusCode}`);
  res.writeHead(result.statusCode, { 'content-type': 'application/json' });
  res.end(result.body);
});

server.listen(port, '127.0.0.1', () => say(`[gateway] listening on 127.0.0.1:${port} hold=${holdMs}ms`));
const stop = () => {
  say(`[gateway] calls ${JSON.stringify(lambdas.providerCalls())}`);
  server.close(() => process.exit(0));
};
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

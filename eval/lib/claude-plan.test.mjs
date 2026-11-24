import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';

import { PlanLimitReached, PlanUnavailable, assertPlanAuth, createPlanRunner } from './claude-plan.mjs';

// A child process double: records how it was spawned and replies with `reply`.
function fakeSpawn(reply) {
  const calls = [];
  const spawnImpl = (cmd, args, opts) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    let stdin = '';
    child.stdin = { write: (s) => { stdin += s; }, end: () => {
      calls.push({ cmd, args, opts, stdin });
      const { stdout = '', stderr = '', code = 0 } = reply({ cmd, args, stdin });
      queueMicrotask(() => {
        if (stdout) child.stdout.emit('data', Buffer.from(stdout));
        if (stderr) child.stderr.emit('data', Buffer.from(stderr));
        child.emit('close', code);
      });
    } };
    return child;
  };
  return { spawnImpl, calls };
}

const ok = (structured) => ({ stdout: JSON.stringify({ type: 'result', subtype: 'success', is_error: false, structured_output: structured, usage: { input_tokens: 3, output_tokens: 9 }, total_cost_usd: 0.02 }) });
const schema = { type: 'object', properties: { a: { type: 'string' } }, required: ['a'], additionalProperties: false };

test('the child never sees API credentials, even when the parent has them', async () => {
  const { spawnImpl, calls } = fakeSpawn(() => ok({ a: 'x' }));
  const runner = createPlanRunner({ spawnImpl, env: { PATH: '/bin', HOME: '/h', ANTHROPIC_API_KEY: 'sk-ant-secret', ANTHROPIC_AUTH_TOKEN: 'tok' } });
  await runner.run({ system: 's', prompt: 'p', schema });
  const env = calls[0].opts.env;
  assert.equal('ANTHROPIC_API_KEY' in env, false);
  assert.equal('ANTHROPIC_AUTH_TOKEN' in env, false);
  assert.equal(env.HOME, '/h');
});

test('every lean flag is passed, the schema as JSON, the prompt on stdin', async () => {
  const { spawnImpl, calls } = fakeSpawn(() => ok({ a: 'x' }));
  await createPlanRunner({ spawnImpl, env: {} }).run({ system: 'rubric', prompt: 'the question', schema });
  const { cmd, args, stdin, opts } = calls[0];
  assert.equal(cmd, 'claude');
  for (const flag of ['-p', '--no-session-persistence', '--strict-mcp-config', '--disable-slash-commands', '--no-chrome']) {
    assert.ok(args.includes(flag), flag);
  }
  const value = (flag) => args[args.indexOf(flag) + 1];
  assert.equal(value('--model'), 'opus');
  assert.equal(value('--tools'), '');
  assert.equal(value('--setting-sources'), '');
  assert.equal(value('--output-format'), 'json');
  assert.equal(value('--system-prompt'), 'rubric');
  assert.equal(value('--json-schema'), JSON.stringify(schema));
  assert.ok(value('--mcp-config').endsWith('.json'));
  assert.equal(stdin, 'the question');
  assert.ok(!opts.cwd.startsWith(process.cwd()), 'runs outside the repo so no CLAUDE.md is found');
});

test('returns the structured output, usage and the notional cost', async () => {
  const { spawnImpl } = fakeSpawn(() => ok({ a: 'yes' }));
  const out = await createPlanRunner({ spawnImpl, env: {} }).run({ system: 's', prompt: 'p', schema });
  assert.deepEqual(out.output, { a: 'yes' });
  assert.equal(out.usage.output_tokens, 9);
  assert.equal(out.costNotional, 0.02);
});

test('a usage-limit reply throws PlanLimitReached; other errors throw PlanUnavailable', async () => {
  const limit = fakeSpawn(() => ({ stdout: JSON.stringify({ is_error: true, result: "You've hit your usage limit · resets 9am" }) }));
  await assert.rejects(createPlanRunner({ spawnImpl: limit.spawnImpl, env: {} }).run({ system: 's', prompt: 'p', schema }), PlanLimitReached);
  const other = fakeSpawn(() => ({ stdout: JSON.stringify({ is_error: true, result: 'Not logged in · Please run /login' }) }));
  await assert.rejects(createPlanRunner({ spawnImpl: other.spawnImpl, env: {} }).run({ system: 's', prompt: 'p', schema }), PlanUnavailable);
  const crash = fakeSpawn(() => ({ stderr: 'boom', code: 1 }));
  await assert.rejects(createPlanRunner({ spawnImpl: crash.spawnImpl, env: {} }).run({ system: 's', prompt: 'p', schema }), PlanUnavailable);
  const noSchema = fakeSpawn(() => ({ stdout: JSON.stringify({ is_error: false, result: 'plain text' }) }));
  await assert.rejects(createPlanRunner({ spawnImpl: noSchema.spawnImpl, env: {} }).run({ system: 's', prompt: 'p', schema }), PlanUnavailable);
});

test('assertPlanAuth accepts only a claude.ai login, checked without API credentials', async () => {
  const plan = fakeSpawn(() => ({ stdout: JSON.stringify({ loggedIn: true, authMethod: 'claude.ai' }) }));
  await assertPlanAuth({ spawnImpl: plan.spawnImpl, env: { ANTHROPIC_API_KEY: 'k' } });
  assert.deepEqual(plan.calls[0].args, ['auth', 'status']);
  assert.equal('ANTHROPIC_API_KEY' in plan.calls[0].opts.env, false);
  const consoleLogin = fakeSpawn(() => ({ stdout: JSON.stringify({ loggedIn: true, authMethod: 'console' }) }));
  await assert.rejects(assertPlanAuth({ spawnImpl: consoleLogin.spawnImpl, env: {} }), PlanUnavailable);
});

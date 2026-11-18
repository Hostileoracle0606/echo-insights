import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStubbedLambdas, fixtures, turnFor } from './stub-lambdas.mjs';

test('a turn is found by its name-free phrase even after names are swapped', () => {
  const swapped = fixtures.turns.t2.text.replace('Odette', 'Person A').replace('Imre', 'Person B');
  assert.equal(turnFor(JSON.stringify({ text: swapped })), fixtures.turns.t2);
  for (const turn of Object.values(fixtures.turns)) assert.ok(turn.text.includes(turn.key));
});

test('the guard refuses and counts any non-local request', async () => {
  const seen = [];
  const lambdas = createStubbedLambdas({
    url: 'http://127.0.0.1:55321', anonKey: 'anon',
    realFetch: async (input) => (seen.push(String(input)), new Response('{}')),
  });
  await assert.rejects(lambdas.guardedFetch('https://generativelanguage.googleapis.com/v1beta/models/x:generateContent'));
  await lambdas.guardedFetch('http://127.0.0.1:55321/rest/v1/notebooks');
  assert.deepEqual(lambdas.providerCalls(), { real: 1, stub: 0 });
  assert.deepEqual(seen, ['http://127.0.0.1:55321/rest/v1/notebooks']);
});

test('an unknown gateway route is a 404, not a handler call', async () => {
  const lambdas = createStubbedLambdas({ url: 'http://127.0.0.1:55321', anonKey: 'anon', realFetch: async () => new Response('{}') });
  assert.equal((await lambdas.gateway('live-sessions', {})).statusCode, 404);
});

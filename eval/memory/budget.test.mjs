import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BudgetExhausted, ProviderAccountError, QuotaExhausted, createBudget, providerFetch } from './budget.mjs';

const SUPABASE = 'http://127.0.0.1:55321';
const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';
const hosts = ['generativelanguage.googleapis.com'];

function fakeFetch(status = 200) {
  const calls = [];
  const realFetch = async (url) => {
    calls.push(String(url));
    return new Response('{}', { status });
  };
  return { calls, realFetch };
}

test('take() is true exactly `limit` times, then false', () => {
  const budget = createBudget(3);
  assert.deepEqual([1, 2, 3, 4, 5].map(() => budget.take()), [true, true, true, false, false]);
  assert.equal(budget.used(), 3);
});

test('a spent budget never reaches the provider', async () => {
  const { calls, realFetch } = fakeFetch();
  const fetchImpl = providerFetch({ realFetch, budget: createBudget(1), providerHosts: hosts });
  await fetchImpl(GEMINI, { method: 'POST' });
  await assert.rejects(fetchImpl(GEMINI, { method: 'POST' }), BudgetExhausted);
  assert.equal(calls.length, 1);
  assert.ok(fetchImpl.stopReason() instanceof BudgetExhausted);
});

test('a provider 429 throws QuotaExhausted and nothing reaches the provider after it', async () => {
  const { calls, realFetch } = fakeFetch(429);
  const budget = createBudget(10);
  const fetchImpl = providerFetch({ realFetch, budget, providerHosts: hosts });
  await assert.rejects(fetchImpl(GEMINI, { method: 'POST' }), QuotaExhausted);
  await assert.rejects(fetchImpl(GEMINI, { method: 'POST' }), QuotaExhausted);
  assert.equal(calls.length, 1, 'no retry past a 429');
  assert.ok(fetchImpl.stopReason() instanceof QuotaExhausted);
});

for (const status of [401, 402, 403]) {
  test(`a provider ${status} (key or billing) stops the run like a 429, so no empty graph is saved`, async () => {
    const { calls, realFetch } = fakeFetch(status);
    const fetchImpl = providerFetch({ realFetch, budget: createBudget(10), providerHosts: hosts });
    await assert.rejects(fetchImpl(GEMINI, { method: 'POST' }), ProviderAccountError);
    await assert.rejects(fetchImpl(GEMINI, { method: 'POST' }), ProviderAccountError);
    assert.equal(calls.length, 1, 'no retry past an account failure');
    assert.match(fetchImpl.stopReason().message, new RegExp(String(status)));
  });
}

test('Supabase-origin calls pass through and never consume budget', async () => {
  const { calls, realFetch } = fakeFetch();
  const budget = createBudget(0);
  const fetchImpl = providerFetch({ realFetch, budget, providerHosts: hosts });
  const response = await fetchImpl(new URL('/rest/v1/notebooks', SUPABASE));
  assert.equal(response.status, 200);
  assert.equal(budget.used(), 0);
  assert.equal(calls.length, 1);
  assert.equal(fetchImpl.stopReason(), null);
});

test('a host that is neither Supabase nor a known provider is refused', async () => {
  const { calls, realFetch } = fakeFetch();
  const fetchImpl = providerFetch({ realFetch, budget: createBudget(5), providerHosts: hosts, supabaseUrl: SUPABASE });
  await assert.rejects(fetchImpl('https://api.groq.com/openai/v1/chat/completions'), /unexpected host/);
  assert.equal(calls.length, 0);
});

test('pace() waits until minIntervalMs after the last provider call; Supabase calls do not count', async () => {
  // Pacing happens before a Lambda is invoked, never inside fetch: the Lambdas
  // start their provider timeout before calling fetch.
  const { realFetch } = fakeFetch();
  let clock = 1_000;
  const waits = [];
  const fetchImpl = providerFetch({
    realFetch, budget: createBudget(5), providerHosts: hosts, minIntervalMs: 7_000,
    now: () => clock, sleep: async (ms) => { waits.push(ms); clock += ms; },
  });
  await fetchImpl.pace();
  await fetchImpl(GEMINI);
  clock += 2_000;
  await fetchImpl(new URL('/rest/v1/notebooks', SUPABASE));
  await fetchImpl.pace();
  await fetchImpl(GEMINI);
  assert.deepEqual(waits, [5_000]);
});

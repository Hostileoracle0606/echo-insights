import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BudgetExhausted, QuotaExhausted, createBudget, providerFetch } from './budget.mjs';

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

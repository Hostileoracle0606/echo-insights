// Free-tier guard: at most `limit` provider calls per run, and no call at all
// after the provider says 429. The Lambdas catch fetch errors and retry, so a
// thrown error alone would be swallowed and retried; the fetch latches its
// first stop and replays it, and the runner reads stopReason() after each call.

export class BudgetExhausted extends Error {
  constructor() { super('provider call budget spent'); this.name = 'BudgetExhausted'; }
}
export class QuotaExhausted extends Error {
  constructor() { super('provider returned 429 (quota)'); this.name = 'QuotaExhausted'; }
}

// 401/402/403: the key is wrong or its billing is spent (Gemini answers 402
// "prepayment credits are depleted"). Every later call would fail the same
// way, and the Lambda would report each as a per-turn "providerUnavailable",
// so stop the run instead of saving a scenario whose turns were all lost.
export class ProviderAccountError extends Error {
  constructor(status) { super(`provider returned ${status} (key or billing)`); this.name = 'ProviderAccountError'; }
}

export function createBudget(limit) {
  let used = 0;
  return {
    take() {
      if (used >= limit) return false;
      used += 1;
      return true;
    },
    used: () => used,
    limit,
  };
}

export function providerFetch({
  realFetch = fetch, budget, providerHosts, supabaseUrl, minIntervalMs = 0,
  now = () => Date.now(), sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  const providers = new Set(providerHosts);
  const supabaseOrigin = supabaseUrl ? new URL(supabaseUrl).origin : null;
  let stop = null;
  let lastProviderCall = -Infinity;
  const fetchImpl = async (url, init) => {
    const target = new URL(String(url));
    if (!providers.has(target.hostname)) {
      if (supabaseOrigin && target.origin !== supabaseOrigin) {
        throw new Error(`unexpected host ${target.hostname}`);
      }
      return realFetch(url, init);
    }
    if (stop) throw stop;
    if (!budget.take()) {
      stop = new BudgetExhausted();
      throw stop;
    }
    lastProviderCall = now();
    const response = await realFetch(url, init);
    if (response.status === 429) {
      stop = new QuotaExhausted();
      throw stop;
    }
    if (response.status === 401 || response.status === 402 || response.status === 403) {
      stop = new ProviderAccountError(response.status);
      throw stop;
    }
    return response;
  };
  fetchImpl.stopReason = () => stop;
  // The free tier also limits requests per minute. Called before a Lambda is
  // invoked, not inside fetch: the Lambdas start their provider timeout first.
  fetchImpl.pace = async () => {
    const wait = lastProviderCall + minIntervalMs - now();
    if (wait > 0) await sleep(wait);
  };
  return fetchImpl;
}

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

export function providerFetch({ realFetch = fetch, budget, providerHosts, supabaseUrl }) {
  const providers = new Set(providerHosts);
  const supabaseOrigin = supabaseUrl ? new URL(supabaseUrl).origin : null;
  let stop = null;
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
    const response = await realFetch(url, init);
    if (response.status === 429) {
      stop = new QuotaExhausted();
      throw stop;
    }
    return response;
  };
  fetchImpl.stopReason = () => stop;
  return fetchImpl;
}

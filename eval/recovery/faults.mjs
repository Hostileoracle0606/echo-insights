// A fetch that fails one chosen request, the three ways a phone loses one:
//   before   – the request never leaves (offline, DNS, socket refused);
//   lost_ack – the server applies it, the response never arrives;
//   kill     – the process dies mid-request: the promise never settles and
//              the request never reaches the server, so nothing after it runs.
// It fires once, on the `after`-th matching request (1-based). Every other
// request, including the client's retry, goes through untouched.
// `triggered()` lets a scenario tell "survived the fault" from "never faulted".

const MODES = new Set(['before', 'lost_ack', 'kill']);

export function faultyFetch({ realFetch, plan }) {
  if (!MODES.has(plan.mode)) throw new Error(`unknown fault mode: ${plan.mode}`);
  const after = plan.after ?? 1;
  let seen = 0;
  let fired = false;

  const fetchImpl = async (url, init) => {
    if (fired || !plan.match(String(url), init)) return realFetch(url, init);
    seen += 1;
    if (seen !== after) return realFetch(url, init);
    fired = true;
    if (plan.mode === 'before') throw new TypeError('network: request did not leave');
    if (plan.mode === 'kill') return new Promise(() => {});
    const response = await realFetch(url, init);
    await response.arrayBuffer().catch(() => {}); // the server finished; the reply is lost
    throw new TypeError('network: response lost');
  };
  return { fetchImpl, triggered: () => fired };
}

// A fetch that fails one chosen request, the ways a phone loses one:
//   before   – the request never leaves (offline, DNS, socket refused);
//   lost_ack – the server applies it, the response never arrives;
//   kill     – the process dies before the request leaves: the promise never
//              settles and the server never sees it, so nothing after it runs;
//   kill_after – the process dies after the server applied the request.
// It fires once, on the `after`-th matching request (1-based). Every other
// request, including the client's retry, goes through untouched.
// `triggered()` lets a scenario tell "survived the fault" from "never faulted".

const MODES = new Set(['before', 'lost_ack', 'kill', 'kill_after']);

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
    if (plan.mode === 'kill_after') {
      await response.arrayBuffer().catch(() => {});
      return new Promise(() => {});
    }
    await response.arrayBuffer().catch(() => {}); // the server finished; the reply is lost
    throw new TypeError('network: response lost');
  };
  return { fetchImpl, triggered: () => fired };
}

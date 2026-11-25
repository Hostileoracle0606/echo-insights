// What deletion should revoke: things a live user may do for themselves.
// The owner is the control; the deleted user must be refused at each step.
import { cell } from '../report.mjs';
import { classifyWrite } from './tables.mjs';

export async function probeSelf({ url, headersByKind, ids, fetchImpl = fetch }) {
  const cells = [];
  const call = async (path, init) => {
    try {
      const response = await fetchImpl(`${url}${path}`, { ...init, signal: AbortSignal.timeout(10_000) });
      return { status: response.status, body: await response.text() };
    } catch {
      return { status: 0, body: '' };
    }
  };
  for (const kind of ['owner', 'deleted_user']) {
    const headers = headersByKind[kind];
    const expected = kind === 'owner' ? 'allow' : 'deny';
    const control = kind === 'owner';

    const user = await call('/auth/v1/user', { method: 'GET', headers });
    cells.push(cell({
      surface: 'self', target: 'auth', credential: kind, operation: 'auth_user', expected, control,
      observed: user.status === 200 ? 'allow' : [401, 403, 404].includes(user.status) ? 'deny' : 'error',
    }));

    const insert = await call('/rest/v1/notebooks', {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json', prefer: 'return=representation' },
      body: JSON.stringify({ user_id: ids[kind], title: 'privacy-matrix self scope', started_at: new Date().toISOString() }),
    });
    // A created row is the owner's legitimate write; for others classifyWrite
    // already calls a 2xx-with-rows a leak, which here means "let through".
    const observed = classifyWrite({ ...insert, changed: false });
    cells.push(cell({
      surface: 'self', target: 'notebooks', credential: kind, operation: 'self_notebook_insert', expected, control,
      observed: observed === 'leak' ? 'allow' : observed,
    }));
  }
  return cells;
}

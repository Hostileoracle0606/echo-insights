// A fixed, synthetic background memory restored into every probe notebook:
// ~50 unrelated entities (gardening, baking, astronomy, chess, a cat…) so a
// scenario's 3–6 entities are ranked among distractors instead of being the
// whole notebook. Same set every scenario; no Gemini calls. A retrieved
// background item is unrelated by construction.
import { readFileSync } from 'node:fs';

export const BACKGROUND = JSON.parse(readFileSync(new URL('./fixtures/background.json', import.meta.url), 'utf8'));
export const isBackground = (id) => typeof id === 'string' && id.startsWith('bg-');

export function backgroundRows({ userId, notebookId, now = '2026-10-01T09:00:00+00:00' }) {
  const owned = { user_id: userId, notebook_id: notebookId };
  return {
    entities: BACKGROUND.entities.map((e) => ({
      ...owned, id: e.id, name: e.name, type: e.type, description: e.description,
      mentions: e.mentions, first_seen: now, last_seen: now, metadata: {},
    })),
    relations: BACKGROUND.relations.map((r) => ({
      ...owned, id: r.id, source_id: r.source_id, target_id: r.target_id, label: r.label, metadata: {}, created_at: now,
    })),
  };
}

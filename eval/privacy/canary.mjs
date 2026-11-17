// Unique marker strings planted in user A's data, in request bodies and in the
// fake provider credential. Finding one where it doesn't belong is a leak.
import { randomBytes } from 'node:crypto';

export function newCanary(label) {
  return `CANARY-${label}-${randomBytes(8).toString('hex')}`;
}

const labelOf = (canary) => canary.slice('CANARY-'.length, canary.lastIndexOf('-'));

export function findLeaks(haystacks, canaries) {
  const text = haystacks
    .filter((h) => h !== null && h !== undefined && h !== '')
    .map((h) => (typeof h === 'string' ? h : JSON.stringify(h)))
    .join('\n');
  return [...new Set(canaries.filter((c) => text.includes(c)).map(labelOf))];
}

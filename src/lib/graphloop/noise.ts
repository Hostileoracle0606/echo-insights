// Vendored from graphloop src/noise.ts (2026-06-17), trimmed to normalizeName.
// filterNoise was dropped (Lumen does its own noise filtering in extract-graph).

export const DEFAULT_NOISE_NAMES = new Set([
  "i",
  "me",
  "my",
  "mine",
  "you",
  "your",
  "yours",
  "we",
  "us",
  "our",
  "they",
  "them",
  "their",
  "today",
  "yesterday",
  "tomorrow",
  "morning",
  "afternoon",
  "evening",
  "night",
  "now",
  "later",
]);

export const normalizeName = (name: string): string =>
  name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9 ]+/g, "")
    .trim();

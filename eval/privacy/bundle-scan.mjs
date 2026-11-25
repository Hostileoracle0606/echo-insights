// Scans shipped client bundles for provider secrets. Findings name the file
// and the pattern, never the matched value.
import { readdir, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

const JWT = /eyJ[A-Za-z0-9_-]+\.(eyJ[A-Za-z0-9_-]+)\.[A-Za-z0-9_-]*/g;

function hasServiceRoleJwt(text) {
  for (const match of text.matchAll(JWT)) {
    try {
      if (JSON.parse(Buffer.from(match[1], 'base64url').toString()).role === 'service_role') return true;
    } catch { /* not a JWT payload */ }
  }
  return false;
}

// Secret-looking variables from a dotenv file. Publishable/anon keys and URLs
// are meant to ship, so they are not treated as secrets.
export function envSecretsFrom(dotenv) {
  const secrets = {};
  for (const line of dotenv.split('\n')) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*"?([^"\n]*)"?\s*$/);
    if (!match) continue;
    const [, name, value] = match;
    if (!/(KEY|SECRET|TOKEN)$/.test(name) || /PUBLISHABLE|ANON/.test(name)) continue;
    if (value.length >= 8) secrets[name] = value;
  }
  return secrets;
}

export function secretPatterns({ internalSecret, envSecrets = {} } = {}) {
  const patterns = [
    { name: 'google_api_key', test: (t) => /AIza[0-9A-Za-z_-]{35}/.test(t) },
    { name: 'groq_api_key', test: (t) => /gsk_[0-9A-Za-z]{20,}/.test(t) },
    { name: 'service_role_jwt', test: hasServiceRoleJwt },
  ];
  for (const [name, value] of Object.entries(envSecrets)) {
    patterns.push({ name: `env:${name}`, test: (t) => t.includes(value) });
  }
  if (internalSecret) patterns.push({ name: 'embed_internal_secret', test: (t) => t.includes(internalSecret) });
  return patterns;
}

async function* files(path) {
  const info = await stat(path).catch(() => null);
  if (!info) return;
  if (info.isFile()) { yield path; return; }
  for (const entry of await readdir(path)) yield* files(join(path, entry));
}

export async function scanBundle(paths, patterns = secretPatterns()) {
  const findings = [];
  for (const root of paths) {
    for await (const file of files(root)) {
      const text = (await readFile(file)).toString('latin1');
      for (const pattern of patterns) {
        if (pattern.test(text)) findings.push({ path: file, pattern: pattern.name });
      }
    }
  }
  return findings;
}

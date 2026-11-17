import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { scanBundle, secretPatterns } from './bundle-scan.mjs';

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const FAKE_GOOGLE = `AIza${'A'.repeat(35)}`;

function bundle(files) {
  const dir = mkdtempSync(join(tmpdir(), 'bundle-scan-'));
  for (const [name, content] of Object.entries(files)) {
    mkdirSync(join(dir, name, '..'), { recursive: true });
    writeFileSync(join(dir, name), content);
  }
  return dir;
}

test('finds a provider key and names the pattern, never the value', async () => {
  const dir = bundle({ 'main.js': `const k="${FAKE_GOOGLE}";`, 'clean.js': 'const x=1;' });
  const findings = await scanBundle([dir]);
  assert.deepEqual(findings.map((f) => f.pattern), ['google_api_key']);
  assert.ok(findings[0].path.endsWith('main.js'));
  assert.ok(!JSON.stringify(findings).includes(FAKE_GOOGLE));
});

test('flags a service_role JWT but not the anon one', async () => {
  const service = `${b64({ alg: 'HS256' })}.${b64({ role: 'service_role' })}.sig`;
  const anon = `${b64({ alg: 'HS256' })}.${b64({ role: 'anon' })}.sig`;
  const dir = bundle({ 'a.js': `x="${anon}"`, 'nested/b.js': `y="${service}"` });
  const findings = await scanBundle([dir]);
  assert.deepEqual(findings.map((f) => f.pattern), ['service_role_jwt']);
});

test('flags the embed internal secret when one is configured', async () => {
  const dir = bundle({ 'c.js': 'z="very-internal-secret-value"' });
  const findings = await scanBundle([dir], secretPatterns({ internalSecret: 'very-internal-secret-value' }));
  assert.deepEqual(findings.map((f) => f.pattern), ['embed_internal_secret']);
});

test('missing paths are skipped, not errors', async () => {
  assert.deepEqual(await scanBundle(['/definitely/not/here']), []);
});

test('flags env secret values by variable name', async () => {
  const dir = bundle({ 'd.js': 'k="dg-live-1234567890abcdef"; u="https://x.supabase.co"' });
  const findings = await scanBundle([dir], secretPatterns({
    envSecrets: { VITE_DEEPGRAM_API_KEY: 'dg-live-1234567890abcdef' },
  }));
  assert.deepEqual(findings.map((f) => f.pattern), ['env:VITE_DEEPGRAM_API_KEY']);
});

test('envSecretsFrom keeps only secret-looking names with real values', async () => {
  const { envSecretsFrom } = await import('./bundle-scan.mjs');
  assert.deepEqual(envSecretsFrom('A_API_KEY=abcdefgh12\nVITE_SUPABASE_PUBLISHABLE_KEY=pub123456\nB_SECRET="s3cr3tvalue"\nSHORT_KEY=x\n# C_KEY=commented'),
    { A_API_KEY: 'abcdefgh12', B_SECRET: 's3cr3tvalue' });
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, generateKeyPairSync, verify } from 'node:crypto';
import {
  CREDENTIAL_KINDS, signJwt, makeSigner, expiredTokenFor, forgedTokenFor, MALFORMED_TOKEN, headersFor,
} from './credentials.mjs';

const LOCAL_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';
const NOW = new Date('2026-11-17T12:00:00Z');

const decode = (segment) => JSON.parse(Buffer.from(segment, 'base64url').toString());
const verifies = (token, secret) => {
  const [h, p, s] = token.split('.');
  return createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url') === s;
};

test('credential kinds cover the matrix rows', () => {
  assert.deepEqual(CREDENTIAL_KINDS,
    ['owner', 'missing', 'anon_only', 'expired', 'forged', 'malformed', 'other_user', 'deleted_user']);
});

test('signJwt yields an HS256 token that verifies with its secret', () => {
  const token = signJwt({ sub: 'u1' }, LOCAL_SECRET);
  assert.equal(token.split('.').length, 3);
  assert.deepEqual(decode(token.split('.')[0]), { alg: 'HS256', typ: 'JWT' });
  assert.ok(verifies(token, LOCAL_SECRET));
});

test('ES256 signer uses the stack key and its kid', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwk = { ...privateKey.export({ format: 'jwk' }), kid: 'kid-1', alg: 'ES256' };
  const token = makeSigner({ jwk })({ sub: 'u1' });
  const [h, p, s] = token.split('.');
  assert.deepEqual(decode(h), { alg: 'ES256', typ: 'JWT', kid: 'kid-1' });
  assert.ok(verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')));
});

test('HS256 signer is the fallback without a JWK', () => {
  assert.ok(verifies(makeSigner({ secret: LOCAL_SECRET })({ sub: 'u1' }), LOCAL_SECRET));
});

test('expired token is genuinely signed but past its exp', () => {
  const token = expiredTokenFor('u1', makeSigner({ secret: LOCAL_SECRET }), NOW);
  const payload = decode(token.split('.')[1]);
  assert.ok(verifies(token, LOCAL_SECRET));
  assert.ok(payload.exp < NOW.getTime() / 1000);
  assert.equal(payload.sub, 'u1');
  assert.equal(payload.role, 'authenticated');
  assert.equal(payload.aud, 'authenticated');
});

test('forged token has valid claims but does not verify with the real secret', () => {
  const token = forgedTokenFor('u1', NOW);
  const payload = decode(token.split('.')[1]);
  assert.ok(payload.exp > NOW.getTime() / 1000);
  assert.equal(verifies(token, LOCAL_SECRET), false);
});

test('headers per kind', () => {
  const tokens = { owner: 'tok-a', other_user: 'tok-b', malformed: MALFORMED_TOKEN };
  assert.deepEqual(headersFor('missing', tokens, 'anon'), {});
  assert.deepEqual(headersFor('anon_only', tokens, 'anon'), { apikey: 'anon' });
  assert.deepEqual(headersFor('owner', tokens, 'anon'), { apikey: 'anon', authorization: 'Bearer tok-a' });
  assert.deepEqual(headersFor('malformed', tokens, 'anon'), { apikey: 'anon', authorization: 'Bearer not-a-jwt' });
  assert.throws(() => headersFor('expired', tokens, 'anon'), /no token for expired/);
});

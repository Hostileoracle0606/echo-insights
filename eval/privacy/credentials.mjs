// The kinds of credential each surface is probed with. Secrets are passed in;
// this module never reads the environment.
import { createHmac, randomBytes } from 'node:crypto';

export const CREDENTIAL_KINDS = Object.freeze(
  ['owner', 'missing', 'anon_only', 'expired', 'forged', 'malformed', 'other_user', 'deleted_user']);

export const MALFORMED_TOKEN = 'not-a-jwt';

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

export function signJwt(payload, secret) {
  const unsigned = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(payload)}`;
  return `${unsigned}.${createHmac('sha256', secret).update(unsigned).digest('base64url')}`;
}

function claims(userId, now, lifetimeSeconds) {
  const issuedAt = Math.floor(now.getTime() / 1000);
  return {
    sub: userId, role: 'authenticated', aud: 'authenticated',
    iat: issuedAt, exp: issuedAt + lifetimeSeconds,
  };
}

export function expiredTokenFor(userId, secret, now) {
  return signJwt(claims(userId, new Date(now.getTime() - 7200_000), 3600), secret);
}

export function forgedTokenFor(userId, now) {
  return signJwt(claims(userId, now, 3600), randomBytes(32).toString('hex'));
}

export function headersFor(kind, tokens, anonKey) {
  if (kind === 'missing') return {};
  if (kind === 'anon_only') return { apikey: anonKey };
  const token = tokens[kind];
  if (!token) throw new Error(`no token for ${kind}`);
  return { apikey: anonKey, authorization: `Bearer ${token}` };
}

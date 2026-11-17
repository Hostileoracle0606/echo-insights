// The kinds of credential each surface is probed with. Secrets are passed in;
// this module never reads the environment.
import { createHmac, createPrivateKey, randomBytes, sign } from 'node:crypto';

export const CREDENTIAL_KINDS = Object.freeze(
  ['owner', 'missing', 'anon_only', 'expired', 'forged', 'malformed', 'other_user', 'deleted_user']);

export const MALFORMED_TOKEN = 'not-a-jwt';

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');

export function signJwt(payload, secret) {
  const unsigned = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(payload)}`;
  return `${unsigned}.${createHmac('sha256', secret).update(unsigned).digest('base64url')}`;
}

// Signs with whatever key the local auth server trusts: its ES256 private JWK
// when given (newer stacks), else the legacy HS256 secret.
export function makeSigner({ secret, jwk }) {
  if (!jwk) return (payload) => signJwt(payload, secret);
  const key = createPrivateKey({ key: jwk, format: 'jwk' });
  return (payload) => {
    const unsigned = `${b64({ alg: 'ES256', typ: 'JWT', kid: jwk.kid })}.${b64(payload)}`;
    const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
    return `${unsigned}.${signature.toString('base64url')}`;
  };
}

function claims(userId, now, lifetimeSeconds) {
  const issuedAt = Math.floor(now.getTime() / 1000);
  return {
    sub: userId, role: 'authenticated', aud: 'authenticated',
    iat: issuedAt, exp: issuedAt + lifetimeSeconds,
  };
}

export function expiredTokenFor(userId, signer, now) {
  return signer(claims(userId, new Date(now.getTime() - 7200_000), 3600));
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

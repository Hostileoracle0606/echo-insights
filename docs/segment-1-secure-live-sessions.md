# Segment 1: secure live voice sessions

Status: implemented and locally tested; not deployed.

## What changed

Previously, the web and Flutter applications opened Gemini Live with the
permanent Gemini key. Anyone who downloaded the application could recover that
key.

The live voice path is now:

```text
Web or iPhone application
  -> sends its existing Supabase sign-in token
  -> Amazon API Gateway
  -> Amazon Lambda authorizer asks Supabase if the sign-in is valid
  -> Amazon Lambda broker asks Supabase if the notebook belongs to that user
  -> broker reads the permanent Gemini key from Amazon Secrets Manager
  -> broker asks Google for a one-use, short-lived credential
  -> application receives only that temporary credential
  -> application connects directly to Gemini Live
```

Audio still travels directly between the user's device and Google. It does not
travel through Amazon Web Services, so this change does not add an audio relay
or the cost and delay of running continuous containers.

## Security rules implemented

- A missing or invalid Supabase sign-in token is rejected.
- A user cannot obtain a live credential for a notebook they cannot read.
- The permanent Gemini credential is not present in the generated cloud
  template.
- Only the credential-broker function can read that secret.
- A temporary credential can start one session, must be used within one minute,
  and expires after thirty minutes.
- The credential is restricted to the selected Gemini live voice model and
  audio responses.
- Web browsers may call the route only from the configured Cloudflare origin.
- The route is limited to ten requests per second, with short bursts of twenty.

## Why the authorizer asks Supabase

The current Supabase project uses the `ES256` signing method. Amazon API
Gateway's built-in token checker currently supports only RSA-based signing
methods. A small Amazon Lambda authorizer therefore asks Supabase to validate
the token. This keeps the current authentication system working without a risky
signing-key migration.

At the expected 500-1,000 users, this extra check happens only when a live
session begins, not for every audio packet. It is a reasonable starting point.

## Tests added

- The cloud template creates a retained secret without a plaintext value.
- The route has an authorizer, throttling, and narrowly scoped secret-read
  permission.
- The authorizer rejects missing credentials and accepts a valid Supabase user.
- The broker rejects unauthenticated users and inaccessible notebooks before
  reading the permanent key.
- The broker requests a constrained one-use token and never returns the
  permanent key.
- The web and Flutter adapters attach the current Supabase access token.
- Both live clients use `access_token` and Google's constrained WebSocket
  method, never the permanent-key query parameter.

## What remains before production use

1. Deploy the stack to the Canada Central region.
2. Enter the real Gemini key into Amazon Secrets Manager without placing it in
   source code or shell history.
3. Put the generated runtime address into the Cloudflare and Flutter build
   configuration.
4. Run one signed-in end-to-end voice session from the web application and one
   from a physical iPhone.
5. Add alarms and request tracing in the later observability segment.

## Deliberate remaining gap

Graph extraction still calls Gemini directly from both clients and therefore
still needs the permanent key in the downloadable build. Segment 1 secures only
live voice. The permanent key can be removed from client builds—and the
production credential scanner can become fully green—after turn extraction
moves behind the server-owned `processTurn` operation.

Google currently labels temporary Gemini Live credentials as Preview. Before
an App Store release, repeat the live-session checks against Google's current
documentation and keep a controlled release fallback.

Official references:

- [Google Gemini temporary credentials](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens)
- [Google Gemini Live WebSocket guide](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket)
- [Amazon API Gateway token authorizers](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html)
- [Supabase signing keys](https://supabase.com/docs/guides/auth/signing-keys)

# Secure live-session runtime interface, version 1

Status: implemented and locally tested; not deployed.

## Purpose

The live-session runtime is the server-owned module that exchanges an
authenticated notebook request for a short-lived Gemini Live credential. Web
and Flutter use network adapters at this seam.

The TypeScript representation lives in
`src/lib/notebook-runtime-contract.ts`. This document is the language-neutral
contract that the Flutter adapter must also follow.

## Authentication

The production adapter sends the current Supabase access token with every
request. Authentication is transport configuration and is not a parameter on
each method. The runtime derives the user identity from that token and verifies
notebook ownership on every operation.

Missing, expired, or invalid authentication is a transport-level authorization
failure. It is never reported as `notFound`.

## Operations

### `startLiveSession(notebookId)`

Returns either:

- `ready`: a short-lived `sessionToken`, its `expiresAt` timestamp, and the
  provider `model`; or
- `rejected`: `notFound`, `rateLimited`, or `providerUnavailable`.

The permanent model-provider credential never crosses this interface. Audio
also does not cross it: after receiving the short-lived credential, the client
connects directly to the live model provider.

Transport failures, invalid authentication, and malformed responses reject the
adapter call. Expected domain refusals return one of the documented `rejected`
codes.

## Out of scope for version 1

Turn processing, notebook snapshots, memory retrieval, and notebook ending are
future server-owned operations. They are intentionally absent from the
TypeScript interface until production adapters and routes implement them.

## Versioning

Version 1 is exposed under a versioned route prefix. Additive response fields
are permitted. Removing fields, changing meanings, or adding required request
fields requires a new major contract version.

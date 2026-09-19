# Secure notebook runtime interface, version 1

Status: implemented and locally tested; not deployed.

## Purpose

The notebook runtime is the server-owned module for authenticated model
operations. It exchanges a live-session request for a short-lived Gemini Live
credential and performs graph extraction without exposing the permanent
credential. Web and Flutter use network adapters at this seam.

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

### `extractFinalizedTurn(notebookId, turnId, extractorVersion, text, mode, context)`

Returns a validated `GraphPatch` containing `entities`, `relations`, and
`supersedes`. The runtime verifies notebook ownership, builds the provider
request, reads the permanent credential from Secrets Manager, and calls Gemini
server-side. Flutter receives the patch, never a credential.

`turnId` and `extractorVersion` form part of the authenticated extraction key.
The first delivery atomically claims that key under a bounded lease before it
calls Gemini. Overlapping deliveries receive `409 inProgress` with a bounded
`retryAfterMs`; the client polls without spending its ordinary failure-retry
budget. Once complete, every delivery receives the same canonical patch.

An input hash binds the key to the immutable normalized transcript and mode.
Derived retrieval/context is deliberately excluded because Flutter reconstructs
it during crash recovery; the first successful claimant fixes the canonical
result. Reusing the key for different immutable input returns
`409 requestIdReused`. An expired lease can be acquired by a replacement
invocation, while owner-token checks prevent the stale invocation from
overwriting the replacement's result. Completed records expire after seven
days.

## Graph-extraction design decisions

- **Run extraction behind the Notebook Runtime.** Flutter sends an
  authenticated request and receives a `GraphPatch`; the permanent Gemini
  credential never enters the application bundle.
- **Reuse the existing Amazon Web Services runtime seam.** Live sessions and
  graph extraction share API Gateway authentication, Secrets Manager, runtime
  configuration, and deployment infrastructure instead of creating a second
  backend path.
- **Use different provider flows for live audio and extraction.** Flutter may
  receive a constrained, short-lived Gemini Live token, while graph extraction
  remains server-side because those temporary credentials do not authorize the
  `generateContent` operation.
- **Reuse one server-held permanent credential.** The same Secrets Manager
  value may mint temporary Live tokens and authorize server-side extraction.
  Separate keys can be introduced later for quota or rotation isolation.
- **Keep Supabase authoritative for notebook ownership.** The runtime forwards
  the user's bearer token to Supabase so existing row-level security determines
  whether the notebook is accessible.
- **Send bounded, structured context.** Flutter selects relevant entities,
  relations, recent turns, and follow-up context. The runtime owns provider
  instructions, request construction, and response interpretation. This keeps
  requests bounded without changing the existing context-selection behavior.
- **Preserve the existing extraction policy.** The server prompts and function
  declaration match the former Flutter implementation so moving the security
  responsibility does not silently change graph semantics.
- **Validate both sides of the provider call.** The runtime rejects malformed
  client input and invalid model output before either can affect canonical
  graph state.
- **Claim by user, notebook, turn, and extractor version.** Conditional
  DynamoDB updates elect one current extraction owner. Input hashes, expiring
  leases, and owner-checked completion make uncertain and overlapping retries
  converge on one canonical patch. Completed records expire after seven days.
- **Inject infrastructure dependencies into the core handler.** Secret reads,
  caching, networking, timing, and model selection are supplied by the Lambda
  entry point. The complete workflow can therefore be tested without live
  Amazon Web Services or Gemini access.

Together these decisions create a small interface—authenticated finalized-turn
data in, validated `GraphPatch` out—while keeping credentials, model details,
retries, and validation inside a server-owned module.

## Out of scope for version 1

Notebook snapshots, memory retrieval, and notebook ending remain future
server-owned operations. Graph merge and Notebook Commit remain client-driven.

## Versioning

Version 1 is exposed under a versioned route prefix. Additive response fields
are permitted. Removing fields, changing meanings, or adding required request
fields requires a new major contract version.

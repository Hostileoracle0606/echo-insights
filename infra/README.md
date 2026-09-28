# Echo Insights Amazon Web Services infrastructure

This folder defines the small Amazon Web Services portion of Echo Insights
with the Amazon Cloud Development Kit.

Segment 1 creates:

- an Amazon Secrets Manager entry for the permanent Gemini credential;
- an Amazon Lambda authorizer that asks Supabase to validate the user's current
  sign-in token;
- an Amazon Lambda credential broker that requests a one-use Gemini Live
  credential, either for a notebook the user can access or for the signed-in
  user alone;
- an Amazon Lambda graph extractor that calls Gemini without exposing the
  permanent credential;
- a retained DynamoDB claim store with leases and canonical results for
  idempotent extraction retries;
- three protected Amazon API Gateway routes; and
- a default gateway stage limited to 10 requests per second with bursts of 20.

The routes are:

`POST /v1/live-sessions`

`POST /v1/notebooks/{notebookId}/live-sessions`

`POST /v1/notebooks/{notebookId}/extractions`

Both live-session routes use the same authorizer and return the same kind of
token: one use, a 30-minute life, limited to the configured Gemini Live model
and audio output. They differ in two ways:

- `POST /v1/live-sessions` is user-scoped. It skips the notebook lookup, because
  the authorizer has already proved who the user is, so a signed-in client can
  hold a token before any notebook is open. Its start window (how long the
  client has to open the Gemini connection) comes from
  `LIVE_SESSION_START_WINDOW_SECONDS` on the broker: default 600, clamped to
  60–1800 seconds and never beyond the token's life.
- `POST /v1/notebooks/{notebookId}/live-sessions` first checks that the notebook
  exists and belongs to the user, and keeps its 60-second start window, so the
  web client is unchanged.

A successful response from either route looks like:

```json
{
  "status": "ready",
  "sessionToken": "auth_tokens/…",
  "expiresAt": "2026-09-06T16:30:00.000Z",
  "newSessionExpiresAt": "2026-09-06T16:10:00.000Z",
  "model": "gemini-3.1-flash-live-preview"
}
```

`newSessionExpiresAt` is when the start window closes; clients should fetch a
fresh token before then.

## Local checks

```sh
npm test
npm run build
npx cdk synth
```

## Deployment inputs

Deployment requires these public configuration values:

- `SupabaseUrl`
- `SupabasePublishableKey`
- `WebOrigin` (optional), the exact Cloudflare-hosted origin allowed to call
  the routes; leave it empty for a native-only deployment, which turns CORS off
- `WorkerReservedConcurrency` (optional, default 0), reserved concurrency for
  each worker Lambda; 0 uses the account's shared pool, which accounts with a
  low concurrency quota need

The permanent Gemini credential is deliberately not a deployment parameter and
must never appear in a command committed to the repository. After deployment,
enter it directly into the `echo-insights/gemini-api-key` secret using the
Amazon Web Services console or a hidden terminal prompt.

The deployment output named `NotebookRuntimeUrl` becomes:

- `VITE_NOTEBOOK_RUNTIME_URL` for the web build; and
- `NOTEBOOK_RUNTIME_URL` for the Flutter build.

The user-scoped route lives on the same API, so these values stay the same
base URL when it is added; clients append `/v1/live-sessions` themselves.

Do not deploy until the owner is ready to enter the permanent credential and
update both client build configurations. The live-session broker returns a
temporary token, while the extraction route returns only a validated graph
patch. Neither route returns the permanent Gemini value.

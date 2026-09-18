# Echo Insights Amazon Web Services infrastructure

This folder defines the small Amazon Web Services portion of Echo Insights
with the Amazon Cloud Development Kit.

Segment 1 creates:

- an Amazon Secrets Manager entry for the permanent Gemini credential;
- an Amazon Lambda authorizer that asks Supabase to validate the user's current
  sign-in token;
- an Amazon Lambda credential broker that checks notebook access and requests a
  one-use Gemini Live credential;
- an Amazon Lambda graph extractor that calls Gemini without exposing the
  permanent credential;
- a retained DynamoDB cache for idempotent extraction retries;
- two protected Amazon API Gateway routes; and
- a default gateway stage limited to 10 requests per second with bursts of 20.

The route is:

`POST /v1/notebooks/{notebookId}/live-sessions`

`POST /v1/notebooks/{notebookId}/extractions`

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
- `WebOrigin`, the exact Cloudflare-hosted origin allowed to call the route

The permanent Gemini credential is deliberately not a deployment parameter and
must never appear in a command committed to the repository. After deployment,
enter it directly into the `echo-insights/gemini-api-key` secret using the
Amazon Web Services console or a hidden terminal prompt.

The deployment output named `NotebookRuntimeUrl` becomes:

- `VITE_NOTEBOOK_RUNTIME_URL` for the web build; and
- `NOTEBOOK_RUNTIME_URL` for the Flutter build.

Do not deploy until the owner is ready to enter the permanent credential and
update both client build configurations. The live-session broker returns a
temporary token, while the extraction route returns only a validated graph
patch. Neither route returns the permanent Gemini value.

# Privacy matrix

Probes every data surface Lumen exposes — 18 user tables, 4 edge functions,
5 API Gateway Lambda routes — with eight kinds of credential, and checks logs
and the shipped web bundle for leaked content or secrets. Local Supabase only.

| Credential | What it is |
|---|---|
| `owner` | User A's real session — the positive control |
| `missing` / `anon_only` | No auth header / publishable key only |
| `expired` | A's identity, signed with the stack's real key, `exp` in the past |
| `forged` | Valid-looking claims signed with a random key |
| `malformed` | `Bearer not-a-jwt` |
| `other_user` | User B's real session against A's data |
| `deleted_user` | User C's still-unexpired token after C was deleted |

Leaks are detected with canaries: unique strings planted in A's rows, in
request bodies and as the fake Gemini key. A canary anywhere it doesn't belong
is a leak. The Lambdas run in-process through their `create*` factories with
real local Supabase; every provider call goes to a counting stub, and a denied
request that still reached the provider fails its cell. The run costs no
provider quota.

## Run

```bash
supabase start
supabase functions serve --env-file <file with EMBED_INTERNAL_SECRET> > /tmp/functions.log 2>&1 &
cp ../../.env .env && npm ci && npx vite build     # optional: bundle scan
source eval/privacy/local-env.sh
PRIVACY_FUNCTION_LOG=/tmp/functions.log PRIVACY_BUNDLE_PATHS=dist/client npm run eval:privacy
rm -rf dist .env                                    # the bundle may hold secrets
```

Exit 0 only when every cell and every owner control passes. The report lands in
`eval/results/<date>-<sha>/privacy.json` and holds names and outcome classes
only (the report builder refuses canaries, JWTs and test emails).

## Not covered

Hosted-only settings (hosted auth configuration, log retention), the iOS app
bundle unless built and passed in `PRIVACY_BUNDLE_PATHS`, and tables added by
migrations newer than this commit.

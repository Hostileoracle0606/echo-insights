# Privacy matrix

Probes every data surface Lumen exposes — 18 user tables, 4 edge functions,
5 API Gateway Lambda routes, and what deletion should revoke — with eight
kinds of credential, and checks logs and the shipped web bundle for leaked
content or secrets. Local Supabase only.

| Credential | What it is |
|---|---|
| `owner` | User A's real session — the positive control |
| `missing` / `anon_only` | No auth header / publishable key only |
| `expired` | A's identity, signed with the stack's real key, `exp` in the past |
| `forged` | Valid-looking claims signed with a random key |
| `malformed` | `Bearer not-a-jwt` |
| `other_user` | User B's real session against A's data |
| `deleted_user` | User C's still-unexpired token after C was deleted. C never owned A's data, so on A's tables it is just another outsider; the `self` probes (read own account, create own notebook) and the user-scoped routes are where it tests deletion |

Leaks are detected with canaries: unique strings planted in A's rows (every
table is seeded), in request bodies and as the fake Gemini key. A canary
anywhere it doesn't belong is a leak.

Every surface has a **positive control** (`control: true` in the report): a
legitimate request that must get through. The owner must read back their own
marker, not merely get a 200. If a function's control fails, its denials are
reported as `error` (inconclusive) instead of `deny`; a table where A has no
rows reports only `error`. Only 401/403/`42501` count as a denial; a
constraint error on a write means RLS already accepted the row and counts as
`allow`.

Provider spend: the Lambdas run in-process with every non-Supabase call sent
to a counting stub, and a denied request that reached it fails. Edge
functions are served **without provider keys**, so they cannot spend; the
`speak-agent` owner control returning "not configured" proves that.

## Run

```bash
supabase start
# env file: EMBED_INTERNAL_SECRET only — no provider keys
supabase functions serve --no-verify-jwt --env-file functions.env > /tmp/functions.log 2>&1 &
cp /path/to/your/.env .env && npm ci && npx vite build   # optional: bundle scan
source eval/privacy/local-env.sh
set -a; . ./functions.env; set +a
PRIVACY_FUNCTIONS_JWT_GATEWAY=off PRIVACY_FUNCTION_LOG=/tmp/functions.log \
  PRIVACY_BUNDLE_PATHS=dist/client npm run eval:privacy
rm -rf dist .env                                          # the bundle may hold secrets
```

Exit 0 only when every cell and every owner control passes. The report lands in
`eval/results/<date>-<sha>/privacy.json` and holds names and outcome classes
only (the report builder refuses canaries, JWTs and test emails).

`--no-verify-jwt`: the local edge gateway's `verify_jwt` only checks HS256,
so on a stack that signs sessions with ES256 it rejects every real user and
the function controls fail. Serving without it tests each handler's own
`getUser` check; drop the flag and set `PRIVACY_FUNCTIONS_JWT_GATEWAY=on` to
measure the gateway instead.

`retrieve-memory/deno.lock` is lockfile version 5, which the edge runtime in
Supabase CLI 2.75 can't read (`Unsupported lockfile version '5'`); move it
aside for the run and restore it after, or upgrade the CLI.

## Not covered

Hosted-only settings (hosted auth configuration, log retention), the iOS app
bundle unless built and passed in `PRIVACY_BUNDLE_PATHS`, and tables added by
migrations newer than this commit.

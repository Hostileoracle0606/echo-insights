# Flutter retrieval release gate

The release gate exercises the deployed `retrieve-memory` function through a
real Supabase user session and Flutter's `RetrieveMemoryService`. A successful
HTTP response or an empty fallback is insufficient to pass.

## Run after deployment

Use a dedicated staging project or local Supabase instance. The test creates
two temporary confirmed users, a notebook, and an entity. It invokes the real
`embed-entities` function to seed a `gte-small@1` embedding. Cleanup deletes only
users created by this run; database foreign keys cascade to their fixture data.
No existing notebook is changed. A cleanup failure fails the gate.

Apply the repository's migrations and deploy/serve `retrieve-memory` and
`embed-entities` first. Set `EMBED_INTERNAL_SECRET` on the Edge Runtime and use
the same value for the test. Native `Supabase.ai` support is required: a local
runtime without it fails the semantic stage and cannot count as release proof.

Provide these environment variables through the shell or CI secret store:

- `RETRIEVAL_GATE_TARGET`: `local` or `staging`; local requires a loopback URL.
- `SUPABASE_URL`: the intended test project's URL.
- `SUPABASE_ANON_KEY`: its public key.
- `SUPABASE_SERVICE_ROLE_KEY`: used only by the host test for fixture setup,
  embedding inspection, and cleanup.
- `EMBED_INTERNAL_SECRET`: authenticates fixture embedding generation.
- `RETRIEVAL_GATE_REPORT`: optional report path; defaults to
  `build/release-gates/retrieval.json`.

Never put privileged values in Flutter `--dart-define` or application assets.
The gate never prints credentials, queries, raw SDK errors, or notebook data.

```sh
flutter pub get
npm run release:retrieval-gate
```

The host-side Flutter test lives outside `test/` so ordinary unit tests require
neither credentials nor a deployed backend. Its runner uses a fresh report for
every invocation and returns nonzero for failures, blocked checks, missing
reports, or unsuccessful Flutter execution.

## What each outcome proves

| Stage | Required evidence |
| --- | --- |
| Configuration | Explicit local/staging target and required credentials |
| Deployment | Unauthenticated request reaches a protected function (401) |
| Authentication | Two real confirmed users can sign in with different sessions |
| Migrations and seed | Notebook/entity writes and retrieval rate/vector RPCs work |
| Lexical retrieval | A client graph sentinel with no stored embedding appears in `entityIds` |
| Embedding generation | Real embed function succeeds and stores a 384-dimensional `gte-small@1` vector |
| Semantic retrieval | Opaque-name entity is returned for its stored description, absent from the client graph's searchable text |
| Flutter consumption | Production adapter returns the ID and it enters compiled/rendered extraction context; without retrieval it does not |
| Unauthorized notebook | A second signed-in user receives the ownership rejection (404) |
| Cleanup | Temporary users and cascading fixture data are removed |

The lexical sentinel cannot be supplied by semantic search or graph expansion.
The semantic fixture has no matching client name/description, relations, or
entries. Therefore neither path can hide the other's failure. Raw function
responses also require string `context` and string-array `entityIds`; a missing
field cannot silently pass through Flutter's permissive parser.

## Release enforcement

The manually dispatched **Flutter retrieval release gate** GitHub workflow:

1. Uses the protected `staging` environment and applies migrations.
2. Deploys both functions from the checked-out revision.
3. Runs the gate and uploads its stage report, including deployment-command
   outcomes. Deployment failure remains a failure even if an older deployment
   responds successfully.
4. Starts the dependent unsigned iOS release build only when the gate succeeds.

Configure staging environment variables `SUPABASE_PROJECT_REF`, `SUPABASE_URL`,
and `NOTEBOOK_RUNTIME_URL`; configure secrets `SUPABASE_ACCESS_TOKEN`,
`SUPABASE_DB_PASSWORD`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, and
`EMBED_INTERNAL_SECRET`. Provision the Edge Runtime's embedding secret before
running this workflow. The URL must match the deployed project reference.

For local release builds, `npm run release:ios:unsigned -- <flutter build flags>`
runs the same gate before invoking `flutter build ios --release --no-codesign`.
Signing, publishing, and physical-device testing are separate steps. Future
publishing jobs must depend on `retrieval-gate` (or run the same gate themselves).
Directly invoking `flutter build` bypasses this repository workflow.

The current checks establish compatibility with the deployed response shape;
they do not introduce a new versioned retrieval contract or change runtime
retrieval behavior.

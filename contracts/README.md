# Network contracts

Language-neutral, versioned interfaces shared by server and application
adapters live here.

`retrieve-memory-v1.schema.json` defines the successful response from the
`retrieve-memory` Edge Function for notebook-scope requests (no `scope` in the
request body). Dart and TypeScript tests consume the same fixtures so neither
platform can change the response shape independently.

`retrieve-memory-v2.schema.json` is the response to `scope: "user"` requests:
recall across all of the user's notebooks. It adds `quotes`, at most 3 of the
user's own past lines (each at most 280 characters) from notebooks other than
the open one, newest first, with the ids the app needs to cite them. Quotes
are a separate field so `context` stays an entities-and-relations packet
that never carries verbatim journal text. The server answers v1 whenever
`scope` is absent, so clients that predate v2 keep working; the v2 fixtures
are `retrieve-memory-v2.{success,empty,no-quotes}.json`.

Breaking changes require a new schema version and a coordinated deployment.
Deploy the backward-compatible server response before releasing a client that
requires the new version.

`fixtures/extract-graph-v1.conversation.json` fixes the canonical conversation
roles at the graph-extraction seam to `user` and `assistant`. UI labels such as
`agent` or `Lumen` must be mapped before crossing that seam.

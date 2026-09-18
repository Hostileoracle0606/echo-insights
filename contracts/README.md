# Network contracts

Language-neutral, versioned interfaces shared by server and application
adapters live here.

`retrieve-memory-v1.schema.json` defines the successful response from the
`retrieve-memory` Edge Function. Dart and TypeScript tests consume the same
fixtures so neither platform can change the response shape independently.

Breaking changes require a new schema version and a coordinated deployment.
Deploy the backward-compatible server response before releasing a client that
requires the new version.

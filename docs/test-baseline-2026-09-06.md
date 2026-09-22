# Test baseline — 2026-09-06

This is the Segment 0 baseline before production behavior is moved behind the
Notebook Runtime interface.

## Automated suites run

| Area                           | Command                                                                                                                | Result                                                                         | What it currently covers                                                                                                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Web domain and adapters        | `npm test`                                                                                                             | 29 existing Vitest tests passed, plus 7 new production-credential tests passed | Graph operations, community grouping, lexical search, retrieval packing, local journal memory, and Supabase Notebook Commit request/response mapping                                |
| Flutter                        | `flutter test`                                                                                                         | 84 tests passed                                                                | Graph merge and agenda logic, Notebook Commit serialization, retrieval serialization, Gemini event parsing, themes, and selected widgets/screens                                    |
| Supabase edge-function helpers | `deno test --allow-net supabase/functions/_shared/embedder.test.ts supabase/functions/retrieve-memory/context.test.ts` | 4 tests passed                                                                 | Deterministic stub embeddings and source-free retrieval-context formatting                                                                                                          |
| PostgreSQL Notebook Commit     | `supabase test db supabase/tests/database/notebook_commit_test.sql`                                                    | 31 assertions passed                                                           | Successful atomic commit, validation rejection, exact replay, changed request-identifier rejection, concurrent revision conflict, rollback, ownership, snapshot, and clear behavior |
| Amazon infrastructure          | `cd infra && npm test -- --runInBand`                                                                                  | 1 placeholder test reported as passed                                          | Nothing: the queue assertion and stack construction are commented out                                                                                                               |
| TypeScript contract            | `npx tsc --noEmit`                                                                                                     | Passed                                                                         | The version 1 Notebook Runtime contract is type-correct                                                                                                                             |

There were 148 meaningful existing automated assertions/tests in the suites
above, plus one assertion-free infrastructure placeholder. Segment 0 adds seven
meaningful production-credential scanner tests.

Additional validation:

- `cd infra && npm run build` passed.
- Targeted linting of the Segment 0 JavaScript and TypeScript files passed.
- The repository-wide `npm run lint` produced no result after approximately one
  minute and was stopped. Its broad traversal needs diagnosis before it can be a
  dependable release check.
- `flutter test` regenerated preview assets. `docs/assets/preview-split-screen.png`
  was already modified before this work and remains modified; it was not reverted.

## Production artifact checks

Both applications build, but both release checks currently fail as expected.
These failures are Segment 1 blockers, not Segment 0 regressions.

### Web

Commands:

```sh
npm run build
npm run check:production-secrets -- dist/client
npm run check:production-secrets -- --configured-values-only dist/server
```

The client artifact contains the configured Gemini credential. The generated
server artifact also contains a local secrets file and configured credentials.
The server check allows harmless credential-name strings needed for runtime
configuration, but still rejects bundled environment files and actual configured
values. The scanner reports paths and credential labels only, never values.

The build also warns that several JavaScript chunks exceed 500 kilobytes after
minification. Bundle splitting is not yet covered by a release budget.

### Flutter Apple release

Commands:

```sh
flutter build ios --release --no-codesign
npm run check:production-secrets -- build/ios/iphoneos/Runner.app
```

The application artifact contains both `.env` and `assets/.env`, along with the
compiled Gemini credential lookup. This confirms that the mobile credential
exposure is present in the built artifact.

## Manual probes that exist but are not in the normal suite

- `test/gemini_live_probe.dart` sends a real text turn to Gemini Live.
- `test/gemini_live_audio_probe.dart` streams a prepared audio fixture to Gemini
  Live.
- `integration_test/mic_capture_probe_test.dart` measures microphone capture on
  an Apple simulator or physical device.

These were not run for this deterministic baseline because they require a real
provider credential, an external model, prepared audio, or a selected device.

## Important gaps in the current suite

### Security and authentication

- No automated end-to-end sign-up, sign-in, sign-out, session refresh, or
  cross-user authorization test exists.
- No Amazon gateway authorizer or short-lived Gemini credential implementation
  exists yet.
- The new scanner proves it can detect unsafe artifacts, but the real production
  artifacts will remain red until Segment 1 removes the credentials.

### Turn processing and persistence

- The web and Flutter orchestration loops are not tested through a shared
  interface.
- No client test simulates “PostgreSQL committed, but the response was lost” and
  proves that the same request identifier is reused.
- PostgreSQL concurrency is tested locally, but the complete client-to-network-
  to-database path is not.
- Direct notebook creation and ending remain outside the tested idempotent write
  path.
- Web and Flutter graph-extraction parity is not tested with shared fixtures.

### Retrieval and embeddings

- The retrieval handler's authentication, ownership check, rate limiting,
  authoritative snapshot loading, vector query, and large-notebook behavior are
  not exercised together.
- The production embedder, embedding worker, self-scheduling continuation, and
  model failure behavior are not tested.
- No transactional outbox, queue worker, duplicate-delivery, or dead-letter
  behavior exists to test yet.

### Amazon infrastructure and operations

- No real infrastructure assertions exist.
- No deployment, rollback, least-privilege permission, logging, alarm, or tracing
  path has been tested.
- No automated deployment workflow exists.

### Scale and App Store readiness

- No concurrent-session, sustained-write, retrieval-latency, provider-quota, or
  cost-per-session test exists.
- The screenshot capture tests generate preview files; they do not compare those
  files against approved golden images, so they are not visual-regression tests.
- The physical-device microphone path and signed App Store archive remain manual.
- Data deletion, privacy disclosures, backup recovery, and production incident
  procedures are not covered.

## Baseline interpretation

The strongest verified area is the PostgreSQL Notebook Commit transaction and
the pure graph/retrieval logic around it. The weakest areas are production
credential handling, tier-spanning orchestration, Amazon infrastructure,
external-provider behavior, and capacity evidence. Subsequent segments should
add tests at those interfaces instead of increasing tests around already-covered
internal helpers.

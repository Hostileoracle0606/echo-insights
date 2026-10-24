# Testing

Every layer has its own suite. They share **contract fixtures**, so a shape
change on one side fails the other.

| Layer | Command | Runner |
| --- | --- | --- |
| Flutter app | `flutter test` | `flutter_test` + `fake_async` (538 tests as of Oct 2026) |
| Static analysis | `flutter analyze` | `flutter_lints` |
| Web client + scripts | `npm test` | Vitest + `node --test` |
| Edge Functions | `deno test … supabase/functions/` (see below) | Deno |
| Database | `supabase test db` | pgTAP (`supabase/tests/database/`) |
| AWS runtime | `cd infra && npm test` | Jest + `node --test` |
| Graphloop vendoring | `node scripts/check-graphloop-sync.mjs` | Fails if `_shared/graphloop` drifted from `src/lib/graphloop` |

## Flutter

```bash
flutter test
```

```bash
flutter test test/turn_state_test.dart
```

How the suite is organised:

- **`test/*_test.dart`**: unit tests for `lib/logic/` and `lib/services/`.
  Pure logic is tested without Flutter widgets. Services take injected
  invokers (`RetrieveMemoryService.withInvoker`, and so on) so no network is
  needed.
- **`test/screens/`, `test/widgets/`**: widget tests for screens and shared
  components, including behaviour such as "a quick reply sends itself" and
  "every target is at least 44 pt".
- **`test/support/`**: shared fakes.
- **`test/fixtures/`** together with **`contracts/fixtures/`**: the same JSON the
  TypeScript and Deno tests load.

### Live probes (not in the normal run)

Files without the `_test.dart` suffix are skipped by `flutter test` and hit
real services. Run them explicitly when you're diagnosing a voice issue:

```bash
flutter test test/gemini_live_probe.dart
```

| Probe | Answers |
| --- | --- |
| `gemini_live_probe.dart` | Does a Gemini Live session work at all (text turn, no mic)? |
| `gemini_live_audio_probe.dart` | Does audio round-trip? |
| `gemini_live_typed_turn_probe.dart` | Do typed turns reach the model? |
| `integration_test/mic_capture_probe_test.dart` | Does on-device mic capture produce PCM? (run on a device) |

## Preview captures

`test/preview_capture_test.dart` renders real widgets with fixture data and
writes PNGs to `docs/assets/preview-*.png`. They serve as the project's visual
regression check and as the source of every image in these docs.

```bash
flutter test test/preview_capture_test.dart
```

After a UI change, regenerate and **review the PNG diff** in your PR. Captures
include every voice dock state, the composer, the transcript page, the graph
canvas, legend and drawer, the dashboard, and closing cards (every layout, plus
loading and failed).

The composite images in `docs/assets/readme/` (hero, dock states, closing
cards, palette) are built from these captures. Rebuild them afterwards:

```bash
python3 scripts/build_doc_images.py
```

> [!NOTE]
> `flutter pub get` may rewrite `pubspec.lock` and the captures may differ by
> a few pixels between machines. Both are environmental. Don't commit
> lockfile drift with a UI change.

## Database (pgTAP)

```bash
supabase start
```

```bash
supabase test db
```

Each `SECURITY DEFINER` function is tested **as a second user too**, so a
missing ownership filter fails loudly. Coverage includes `commit_notebook`,
user memory, conversation modes and turns, memory control and session cards.

## Edge Functions

```bash
deno test --allow-net --allow-env --allow-read --config supabase/functions/retrieve-memory/deno.json supabase/functions/
```

`retrieve-memory` has handler, context and contract tests. `_shared/` has the
embedder and the retrieve-memory contract.

## AWS runtime

```bash
cd infra && npm test
```

```bash
cd infra && npx cdk synth
```

Lambda tests cover the authorizer, live-session, extract-graph and
close-session, plus `session-card-contract.test.mjs` against the shared
fixtures.

## Release gate

**Flutter retrieval release gate** (`.github/workflows/flutter-retrieval-release.yml`,
run manually) is the pre-release check:

1. Requires staging configuration (project ref, keys, `EMBED_INTERNAL_SECRET`).
2. Applies migrations to **staging** and deploys `retrieve-memory` +
   `embed-entities`.
3. Proves the gate rejects partial success (`npm run test:retrieval-gate`).
4. Runs an authenticated recall end to end (`npm run release:retrieval-gate`).
5. Builds an unsigned iOS release.
6. Scans `Runner.app` for bundled credentials (`scripts/production-secrets.mjs`).

Run the credential scan locally after a release build:

```bash
npm run check:production-secrets -- build/ios/iphoneos/Runner.app
```

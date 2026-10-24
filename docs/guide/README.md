# Lumen documentation

Start with the [project README](../../README.md) for the overview, then pick
the guide that matches what you're doing.

| | Guide | Covers |
| --- | --- | --- |
| 🧭 | [User guide](user-guide.md) | Every screen, control and state, with screenshots |
| 🏗️ | [Architecture](architecture.md) | System diagram, turn lifecycle, data model, recall, design decisions |
| 🚀 | [Getting started](getting-started.md) | Run the app, configure it, and stand up your own backend |
| 🗄️ | [Backend reference](backend.md) | Runtime routes, tables, RPCs, Edge Functions, migrations, deploy order |
| 🧪 | [Testing](testing.md) | Every suite, preview captures, the release gate |
| 🎨 | [Design system](design-system.md) | Colour, type, components, motion |

Elsewhere in the repo:

- [`contracts/README.md`](../../contracts/README.md): versioned cross-platform API schemas
- [`infra/README.md`](../../infra/README.md): the AWS runtime in detail
- [`docs/superpowers/specs/`](../superpowers/specs) and [`plans/`](../superpowers/plans): dated design specs and their implementation plans
- Design deep dives: [finalized-turn extraction](../finalized-turn-extraction.md),
  [notebook runtime interface](../notebook-runtime-interface.md),
  [secure live sessions](../segment-1-secure-live-sessions.md),
  [visual system audit](../visual-system-audit.md)

## Keeping these docs current

- **Screenshots** come from `flutter test test/preview_capture_test.dart`.
  Regenerate them with any UI change, then rebuild the composites in
  `docs/assets/readme/` with `python3 scripts/build_doc_images.py`.
- **Diagrams** are Mermaid blocks, so edit them as text and GitHub renders them.
- **Facts** (routes, tables, env names) should be checked against the source
  they cite. Every guide links to its source files.

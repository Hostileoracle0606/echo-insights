# Startup and responsiveness timing

Where the person waits, per stage, as p50/p95 with N, device, build mode,
network profile and history size. Plan:
`docs/superpowers/plans/2026-11-18-startup-responsiveness.md`.

## What is measured

The app emits one content-free line per mark, only when built with
`--dart-define=LUMEN_TIMING=1`:

```
[lumen-timing] {"v":1,"stage":"notebook_open","phase":"end","t_ms":812,"dur_ms":143,"mode":"profile","size":10,"overlap":false}
```

Lines carry stage names, millisecond offsets, counts and booleans only
(`lib/logic/timing_marks.dart` enforces an allow-list; `parse.mjs` rejects
any other string value). All offsets come from one monotonic `Stopwatch`
started at the top of `main()`.

| Stage | Kind | Value | From → to |
|---|---|---|---|
| `process_start` | mark | t_ms (≈0) | Dart `main()` entry |
| `first_frame` | mark | t_ms | `main()` → first frame drawn |
| `home_interactive` | mark | t_ms | `main()` → notebooks list first rendered (`count`, `size`) |
| `launch_to_first_frame_host` | span | dur_ms | `simctl launch` on the host → first_frame line arrives (simulator only; includes native/engine start that `main()` can't see, plus a few ms of pty latency) |
| `notebook_open` | begin/end | dur_ms | open a notebook → snapshot, saved turns and turn journal loaded (`size`, `overlap`) |
| `tap_to_mic_open` | begin/end | dur_ms | mic tap from idle → microphone capturing |
| `user_turn_end_to_first_audio` | begin/end | dur_ms | user transcript finalized → first assistant audio chunk (once per turn) |
| `retrieval` | span | dur_ms | in-app retrieve-memory call (`scope`: 0 notebook, 1 user; `count` entities) |
| `extraction` | span | dur_ms | retrieval + extraction model call for a turn (`ok`) |
| `commit` | span | dur_ms | notebook commit RPC (`ok`, `retry`) |
| `opening_prep` | span | dur_ms | session-brief state reload (`ok`, `overlap` = a live session was active) |
| `retrieval_server` | span | dur_ms | Node → local `retrieve-memory`, user scope (`count`, `ok`) |

`size` is the entity count as an order-of-magnitude bucket: 0, 1, 10, 100,
1000+. The seeded histories 0 / 50 / 500 report as 0 / 10 / 100.

**Incomplete** = a begin with no end (crash, cancel, superseded) or an end
with no begin. It is counted per stage, never dropped. **Failed** = a span
with `ok:false`; counted and kept out of the percentiles.

## Build modes

Flutter cannot build profile mode for the iOS simulator ("Profile mode is not
supported for simulators"). Simulator runs are therefore **debug (JIT)** and
labelled `mode=debug`; they overstate start-up time compared with a shipped
build. Device runs (device-sheet.md) are **profile**. `parse.mjs` refuses
debug logs unless the caller passes `allowDebug`, a run may not mix modes, and
`summarize.mjs` refuses to merge groups with a different device, mode or
network. Never put simulator and device numbers in one figure.

## Run it (local Supabase only)

```bash
source eval/privacy/local-env.sh
export TIMING_USER_PASSWORD='…'            # any strong throwaway value
node eval/timing/seed.mjs --entities 0     # prints the new timing-eval-…@example.test
```

Simulator cold start (×20 per history size), on a dedicated simulator:

```bash
xcrun simctl create lumen-timing "iPhone 17 Pro" && xcrun simctl boot lumen-timing
BUILD=1 eval/timing/collect.sh lumen-timing 1 warmup   # build (debug + LUMEN_TIMING) and install
# sign in once in the simulator as the timing user; the session survives relaunches
eval/timing/collect.sh lumen-timing 20 sim-cold-0
node eval/timing/seed.mjs --entities 50 --email timing-eval-…@example.test
eval/timing/collect.sh lumen-timing 20 sim-cold-50
node eval/timing/seed.mjs --entities 500 --email timing-eval-…@example.test
eval/timing/collect.sh lumen-timing 20 sim-cold-500
```

Each run terminates the app, waits 2 s, launches it with `--console-pty` and
keeps 20 s of lines in `eval/results/<date>-<sha>/timing/<label>-<n>.jsonl`.
Delete the `warmup-*` file before summarizing.

Server-side retrieval (×50 per size after 5 discarded warm-up calls; paced
under the function's 30/min-per-user and 20/min-per-notebook limits):

```bash
node eval/timing/retrieval.mjs --email timing-eval-…@example.test --size 0   # after seeding 0
```

Then write `meta.json` beside the runs (`{group: {device, mode, network,
history}}`) and summarize:

```bash
npm run eval:timing:summary -- eval/results/<date>-<sha>/timing
node eval/timing/seed.mjs --cleanup        # delete every timing-eval user
```

## Limits worth stating

- Simulator figures are debug builds on a Mac, not a phone.
- `process_start` is Dart `main()`, not the OS process start; the host span
  covers the gap on the simulator only.
- Seeded embeddings are synthetic unit vectors: pgvector does real work, but
  semantic matches are meaningless, so ranking after the match is lighter
  than with real memories.
- Local edge functions may be shared with other eval runs on the same stack;
  `meta.json` says so when they were.
- Spans (`retrieval`, `extraction`, `commit`, `opening_prep`) are emitted when
  the stage finishes; a crash mid-span leaves no line, so those stages cannot
  show `incomplete`.

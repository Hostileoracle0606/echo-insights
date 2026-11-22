#!/usr/bin/env bash
# EC-01 rebuild test helper. Builds Lumen with the context rebuild flag,
# captures [voice] log lines and summarises reply latency around rebuilds.
#
#   scripts/ec01-rebuild-test.sh runtime                 Notebook runtime on :8787 against staging
#   scripts/ec01-rebuild-test.sh sim [max_turns]        Simulator: build, install, launch, log
#   scripts/ec01-rebuild-test.sh device <id> [max_turns] Device: flutter run, log
#   scripts/ec01-rebuild-test.sh summary <log>           Timing table for a captured log
#
# Builds use the lumen-staging project by default (.env.staging, with the
# runtime from `runtime` running in another terminal). EC01_ENV=dev builds
# against production instead.
#
# Logs go to test-runs/ec01-<timestamp>.log (gitignored). Only [voice] lines
# are kept: timings and markers, no conversation content.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.echoinsights.lumen"
SIM="${EC01_SIM:-26922240-CDE0-48AA-B41F-634DC207A1E3}"
RUN_DIR="$ROOT/test-runs"
ENV_NAME="${EC01_ENV:-staging}"
STAGING_REF="roextftlnorvkjevqcsl"

defines() {
  local turns="$1"
  echo "--dart-define-from-file=.env.$ENV_NAME" \
       "--dart-define=CONTEXT_REBUILD_ENABLED=true" \
       "--dart-define=CONTEXT_REBUILD_MAX_TURNS=$turns"
}

new_log() {
  mkdir -p "$RUN_DIR"
  echo "$RUN_DIR/ec01-$(date +%Y%m%d-%H%M%S).log"
}

summary() {
  local log="$1"
  [[ -f "$log" ]] || { echo "No log at $log" >&2; exit 1; }
  python3 -I - "$log" <<'PY'
import re, statistics, sys

rows, after_rebuild, rebuilds = [], False, []
for line in open(sys.argv[1], errors="replace"):
    stamp = line[11:23] if line[:4].isdigit() else ""
    m = re.search(r"\[voice\]\[rebuild\] (.*)", line)
    if m:
        msg = m.group(1).strip()
        if msg.startswith("start"):
            rebuilds.append([stamp, msg, None])
        elif msg.startswith("seeded") or msg.startswith("did not"):
            if rebuilds:
                rebuilds[-1][2] = msg
            after_rebuild = msg.startswith("seeded")
        continue
    m = re.search(r"\[voice\]\[latency\] (typed|spoken) turn → reply audio \+(\d+)ms(.*)", line)
    if m:
        kind, ms, rest = m.group(1), int(m.group(2)), m.group(3)
        tool = "tool" if "tool call" in rest else "plain"
        rows.append((stamp, kind, tool, ms, after_rebuild))
        after_rebuild = False

if not rows and not rebuilds:
    print("No [voice] latency or rebuild lines found.")
    sys.exit(0)

print(f"{'time':<13}{'turn':<8}{'reply':<7}{'first audio':>12}  note")
events = [(r[0], "r", r) for r in rebuilds] + [(r[0], "t", r) for r in rows]
for _, kind, r in sorted(events, key=lambda e: e[0]):
    if kind == "r":
        print(f"{r[0]:<13}-- rebuild {r[1]} | {r[2] or 'not finished'}")
    else:
        note = "FIRST AFTER REBUILD" if r[4] else ""
        print(f"{r[0]:<13}{r[1]:<8}{r[2]:<7}{r[3]:>10}ms  {note}")

print()
for kind in ("spoken", "typed"):
    for tool in ("plain", "tool"):
        normal = [r[3] for r in rows if r[1] == kind and r[2] == tool and not r[4]]
        post = [r[3] for r in rows if r[1] == kind and r[2] == tool and r[4]]
        if not normal and not post:
            continue
        med = lambda xs: f"{statistics.median(xs):.0f}ms (n={len(xs)})" if xs else "—"
        print(f"{kind} {tool}: normal median {med(normal)}, after rebuild {med(post)}"
              + (f", normal max {max(normal)}ms" if normal else ""))
PY
}

require_runtime() {
  [[ "$ENV_NAME" == staging ]] || return 0
  curl -s -o /dev/null -X OPTIONS http://127.0.0.1:8787/v1/live-sessions || {
    echo "Start the staging runtime first: $0 runtime" >&2
    exit 1
  }
}

case "${1:-}" in
  runtime)
    # Gemini key from the main checkout's .env (gitignored); the Supabase
    # values from .env.staging. The runtime refuses production.
    key="$(grep '^GEMINI_API_KEY=' "$ROOT/../echo-insights/.env" | cut -d= -f2- | tr -d "\"' ")"
    [[ -n "$key" ]] || { echo "No GEMINI_API_KEY in echo-insights/.env" >&2; exit 1; }
    set -a; source "$ROOT/.env.staging"; set +a
    cd "$ROOT"
    GEMINI_API_KEY="$key" LOCAL_RUNTIME_TEST_PROJECT="$STAGING_REF" \
      exec node scripts/local-runtime.mjs
    ;;
  sim)
    require_runtime
    turns="${2:-3}"
    cd "$ROOT"
    xcrun simctl boot "$SIM" 2>/dev/null || true
    open -a Simulator
    # shellcheck disable=SC2046
    flutter build ios --simulator --debug $(defines "$turns")
    xcrun simctl install "$SIM" build/ios/iphonesimulator/Runner.app
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
    log="$(new_log)"
    echo "Logging to $log (Ctrl-C to stop, then: $0 summary $log)"
    xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    xcrun simctl spawn "$SIM" log stream --style compact --level debug \
      --predicate 'process == "Runner"' | grep --line-buffered '\[voice\]' | tee "$log"
    ;;
  device)
    require_runtime
    device="${2:?device id, see: flutter devices}"
    turns="${3:-3}"
    cd "$ROOT"
    log="$(new_log)"
    echo "Logging to $log (q to quit, then: $0 summary $log)"
    # flutter run prints "flutter: [voice]..." without a timestamp; add one.
    # shellcheck disable=SC2046
    flutter run -d "$device" $(defines "$turns") 2>&1 \
      | while IFS= read -r line; do
          case "$line" in
            *"[voice]"*) printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.000')" "$line" | tee -a "$log" ;;
            *) printf '%s\n' "$line" ;;
          esac
        done
    ;;
  summary)
    summary "${2:?log file}"
    ;;
  *)
    sed -n '2,8p' "$0"
    exit 1
    ;;
esac

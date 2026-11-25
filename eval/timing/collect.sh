#!/usr/bin/env bash
# Cold-start timing on an iOS simulator.
#
#   source eval/privacy/local-env.sh
#   BUILD=1 eval/timing/collect.sh <device> <runs> <label>   # build + install, then run
#   eval/timing/collect.sh <device> <runs> <label>           # reuse the installed build
#
# Flutter cannot build profile mode for a simulator, so this build is debug
# (JIT): every mark says mode=debug and the summary labels it. Device runs
# (device-sheet.md) are profile. Never mix the two in one figure.
#
# Each run: terminate the app, wait 2 s, launch it and keep
# 20 s of [lumen-timing] lines in eval/results/<date>-<sha>/timing/<label>-<n>.jsonl.
# The app must already be signed in (the session survives relaunches).
set -euo pipefail
device=${1:?device name or UDID}
runs=${2:?number of runs}
label=${3:?label, e.g. sim-cold-50}
bundle=com.echoinsights.lumen
root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/eval/results/$(date +%Y-%m-%d)-$(git -C "$root" rev-parse --short HEAD)/timing"
mkdir -p "$out"

case "${SUPABASE_URL:-}" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "collect.sh: SUPABASE_URL must be the local stack (source eval/privacy/local-env.sh)" >&2; exit 2 ;;
esac

if [ "${BUILD:-0}" = 1 ]; then
  (cd "$root" && flutter build ios --simulator --debug \
    --dart-define=LUMEN_TIMING=1 \
    --dart-define=SUPABASE_URL="$SUPABASE_URL" \
    --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY")
  xcrun simctl install "$device" "$root/build/ios/iphonesimulator/Runner.app"
fi

for n in $(seq 1 "$runs"); do
  xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
  sleep 2
  node "$root/eval/timing/capture.mjs" "$device" "$bundle" 20 "$out/$label-$n.jsonl"
  printf '%s %d/%d: %s lines\n' "$label" "$n" "$runs" "$(wc -l < "$out/$label-$n.jsonl" | tr -d ' ')"
done
xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true

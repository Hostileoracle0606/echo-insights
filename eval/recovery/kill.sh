#!/usr/bin/env bash
# Simulator kill test: kills the app mid-turn with `simctl terminate`,
# relaunches it, and audits what landed. Local Supabase only; no provider.
#
#   eval/recovery/kill.sh [runs-per-case]      (default 5)
#
# Two cases, each run [runs-per-case] times on a fresh test user:
#   transcription — turn 2 is still being transcribed (partial input
#                   transcription streamed, nothing final) when the app dies;
#   extraction    — turn 2 was submitted; the kill lands a set delay after
#                   the gateway saw its extraction begin, so across runs it
#                   falls in extraction, around the commit, or after it.
# The plan times the kill from the app's [lumen-timing] extraction mark; that
# mark is not on this branch, so the gateway's own "begin" line is the anchor
# and the delays below are the fixed-delay fallback.
#
# Uses its own simulator ("Recovery Eval iPhone"), so it can't disturb one
# another session is driving. Writes eval/results/<date>-<sha>/recovery-kill.json.
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNS=${1:-5}
DEVICE_NAME=${RECOVERY_SIM_NAME:-Recovery Eval iPhone}
BUNDLE=com.echoinsights.lumen
PORT=${RECOVERY_GATEWAY_PORT:-55399}
# Each extraction response is held this long, so a kill can land inside it.
export RECOVERY_GATEWAY_HOLD_MS=${RECOVERY_GATEWAY_HOLD_MS:-2000}
DELAYS_transcription=(0 150 300 600 1200)
DELAYS_extraction=(0 400 800 1200 1800)

# shellcheck disable=SC1091
source eval/privacy/local-env.sh
if [[ -z "${SUPABASE_URL:-}" ]]; then
  echo "kill.sh: local Supabase is not running" >&2
  exit 2
fi

udid=$(xcrun simctl list devices available -j | node -e '
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    const all = Object.values(JSON.parse(s).devices).flat();
    const d = all.find((d) => d.name === process.argv[1]);
    if (d) process.stdout.write(d.udid);
  });' "$DEVICE_NAME")
if [[ -z "$udid" ]]; then
  runtime=$(xcrun simctl list runtimes -j | node -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const ios = JSON.parse(s).runtimes.filter((r) => r.platform === "iOS" && r.isAvailable);
      process.stdout.write(ios.at(-1).identifier);
    });')
  udid=$(xcrun simctl create "$DEVICE_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
os=$(xcrun simctl list devices -j | node -e '
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    for (const [rt, ds] of Object.entries(JSON.parse(s).devices))
      if (ds.some((d) => d.udid === process.argv[1])) process.stdout.write(rt.split(".").pop());
  });' "$udid")

work=$(mktemp -d "${TMPDIR:-/tmp}/recovery-kill.XXXXXX")
node eval/recovery/gateway-server.mjs >"$work/gateway.log" 2>&1 &
gateway=$!
flutter_pid=
cleanup() {
  [[ -n "$flutter_pid" ]] && kill "$flutter_pid" 2>/dev/null || true
  kill "$gateway" 2>/dev/null || true
  wait "$gateway" 2>/dev/null || true
  node eval/recovery/kill-audit.mjs sweep >/dev/null 2>&1 || true
}
trap cleanup EXIT
for _ in $(seq 1 50); do grep -q listening "$work/gateway.log" && break; sleep 0.2; done
node eval/recovery/kill-audit.mjs sweep >/dev/null
echo "logs: $work"

# Waits until [file] has [count] lines matching [pattern] (fixed string).
wait_for() {
  local file=$1 pattern=$2 count=$3 limit=$4 waited=0
  until [[ $(grep -cF -- "$pattern" "$file" 2>/dev/null || true) -ge $count ]]; do
    sleep 0.05
    waited=$((waited + 1))
    if ((waited > limit * 20)); then return 1; fi
  done
}

run_app() {
  local phase=$1 kase=$2
  flutter test integration_test/recovery_kill_test.dart -d "$udid" \
    --dart-define=RECOVERY_PHASE="$phase" --dart-define=RECOVERY_CASE="$kase" \
    --dart-define=RECOVERY_EMAIL="$email" --dart-define=RECOVERY_PASSWORD="$password" \
    --dart-define=RECOVERY_NOTEBOOK_ID="$notebook" \
    --dart-define=SUPABASE_URL="$SUPABASE_URL" --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
    --dart-define=NOTEBOOK_RUNTIME_URL="http://127.0.0.1:$PORT"
}

field() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]]))' "$1" "$2"; }

: >"$work/runs.jsonl"
for kase in transcription extraction; do
  delays_var="DELAYS_${kase}[@]"
  delays=("${!delays_var}")
  for run in $(seq 1 "$RUNS"); do
    delay=${delays[$(((run - 1) % ${#delays[@]}))]}
    setup=$(node eval/recovery/kill-audit.mjs setup)
    user=$(field "$setup" userId)
    email=$(field "$setup" email)
    password=$(field "$setup" password)
    notebook=$(field "$setup" notebookId)
    start_log="$work/$kase-$run-start.log"

    run_app start "$kase" >"$start_log" 2>&1 &
    flutter_pid=$!
    if [[ $kase == transcription ]]; then
      trigger=(wait_for "$start_log" "[recovery-kill] turn2 transcribing" 1 900)
    else
      trigger=(wait_for "$work/gateway.log" "extractions begin notebook=$notebook" 2 900)
    fi
    if ! "${trigger[@]}"; then
      echo "$kase run $run: never reached the kill point (see $start_log)"
      kill "$flutter_pid" 2>/dev/null || true
      wait "$flutter_pid" 2>/dev/null || true
      echo "{\"case\":\"$kase\",\"run\":$run,\"delay_ms\":$delay,\"outcome\":\"error\",\"error\":\"kill point not reached\"}" >>"$work/runs.jsonl"
      node eval/recovery/kill-audit.mjs delete "$user"
      continue
    fi
    sleep "$(awk "BEGIN { print $delay / 1000 }")"
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
    kill "$flutter_pid" 2>/dev/null || true
    wait "$flutter_pid" 2>/dev/null || true
    flutter_pid=
    before=$(grep -qF "turn2 committed before kill" "$start_log" && echo true || echo false)

    resume_log="$work/$kase-$run-resume.log"
    run_app resume "$kase" >"$resume_log" 2>&1 || true
    found=$(grep -oE 'resume found=[0-9]+' "$resume_log" | head -1 | cut -d= -f2 || true)
    drained=$(grep -qE 'resume done drained=true' "$resume_log" && echo true || echo false)

    line=$(node eval/recovery/kill-audit.mjs audit "$user" "$kase" "$run" "$delay" "$found" "$drained" "$before")
    echo "$line" >>"$work/runs.jsonl"
    echo "$kase run $run delay=${delay}ms found=${found:-?}: $(field "$line" outcome) $(field "$line" partial_turn)"
    node eval/recovery/kill-audit.mjs delete "$user"
  done
done

node eval/recovery/kill-audit.mjs report "$work/runs.jsonl" "iPhone 17 simulator, ${os}"

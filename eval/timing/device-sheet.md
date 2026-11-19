# Device timing sheet (owner-run)

Voice stages need real speech and a real phone, so these runs are by hand.
They produce the same `[lumen-timing]` lines as the simulator runs and are
summarized by the same script. Budget: **10 voice sessions** (5 Wi-Fi, 3
"LTE", 2 "3G"), which is ≤10 Gemini Live sessions for the day; check with
any other Live use (memory eval spoken answers) first.

Record every session, including failures. A session that crashes, drops or
never answers is a result: keep its log file and write what happened in the
table at the bottom. Never redo a session because its number looks bad.

## 0. Once: what you need

- An iPhone in Developer Mode, on the same Wi-Fi as the Mac, and its UDID
  (`flutter devices`).
- The local stack running (`supabase status`), edge functions served
  (`supabase functions serve`, with `retrieve-memory/deno.lock` moved aside
  while serving, as in `eval/privacy/README.md`).
- Your free-tier `GEMINI_API_KEY` in the shell (for the local runtime only;
  it never goes into the app).
- The Mac's LAN address: `ipconfig getifaddr en0` → call it `$MAC_IP`.

## 1. Once: seed, runtime, build

```bash
cd ~/Developer/echo-insights
source eval/privacy/local-env.sh
export TIMING_USER_PASSWORD='<throwaway value>'
node eval/timing/seed.mjs --entities 50          # prints timing-eval-…@example.test; note it
# Terminal 2 — the live-session broker and extraction route, on 0.0.0.0:8787:
SUPABASE_PUBLISHABLE_KEY="$SUPABASE_ANON_KEY" GEMINI_API_KEY="$GEMINI_API_KEY" \
  node scripts/local-runtime.mjs
```

Check from the phone's Safari that the Mac is reachable:
`http://$MAC_IP:55321/auth/v1/health` shows JSON. If not, stop: the
firewall or network blocks it, and nothing below will work.

Build and install a **profile** build with timing on (the first `flutter
run` installs it; press `q` once the app shows, to detach):

```bash
flutter run --profile -d <UDID> \
  --dart-define=LUMEN_TIMING=1 \
  --dart-define=SUPABASE_URL=http://$MAC_IP:55321 \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=NOTEBOOK_RUNTIME_URL=http://$MAC_IP:8787
```

On first launch allow **Local Network** and **Microphone**, then sign in as
the timing user. If sign-in fails with a transport-security error, stop and
note it (do not edit Info.plist on the eval branch).

```bash
DIR=eval/results/$(date +%Y-%m-%d)-$(git rev-parse --short HEAD)/timing
mkdir -p "$DIR"
```

## 2. Network profile

Settings → Developer → Network Link Conditioner (enable "Network Link
Conditioner" under Developer if it's missing):

| Sessions | Profile | Label |
|---|---|---|
| 1–5 | off (plain Wi-Fi) | `device-wifi` |
| 6–8 | **LTE** | `device-lte` |
| 9–10 | **3G** | `device-3g` |

## 3. Each session (n = 1, 2, … within its label)

1. Force-quit Lumen (swipe it away in the app switcher). Wait 5 s.
2. Launch it cold from the Mac with the log going to one file per session
   (`flutter run` relaunches a fresh process and prints the app's output;
   `flutter logs` does not stream reliably from recent iOS devices):
   ```bash
   RUN() { flutter run --profile -d <UDID> \
     --dart-define=LUMEN_TIMING=1 \
     --dart-define=SUPABASE_URL=http://$MAC_IP:55321 \
     --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
     --dart-define=NOTEBOOK_RUNTIME_URL=http://$MAC_IP:8787 2>&1 |
     grep --line-buffered '\[lumen-timing\]' | tee "$DIR/$1.jsonl"; }
   RUN device-wifi-1        # label + n per the table
   ```
3. Wait for the notebooks list.
4. Open the newest notebook (it has earlier entries, so it opens quietly).
5. Sessions 1–3 only: leave it **on the record** (each turn spends one
   extraction call: 3 turns × 3 sessions = 9 calls). Sessions 4–10: turn
   **Off the record** on before speaking, so turns are not extracted.
6. Tap the mic. Read these three turns, waiting for Lumen to answer each:
   - "Today I mostly worked on the amber harbor project."
   - "I also walked past the brisk meadow on the way home."
   - "Remind me what I said about the amber harbor before."
7. End the session. Wait 10 s (commit and brief work finish), then press
   `q` in the `flutter run` terminal.
8. Fill in a row below.

Only `[lumen-timing]` lines reach the results file: the rest of the
`flutter run` console (device name, UDID, paths, app error text) is filtered
out before anything is written, because `eval/results` is committed. You see
only timing lines in the terminal while it runs; that's expected.

Each file is one process from cold start (launched by `flutter run`, not
an icon tap: say so in the report), and `parse.mjs` ignores everything except `[lumen-timing]`
lines. A file with `mode` other than `profile` means the wrong build is
installed: stop and rebuild.

## 4. Summarize

Add the device groups to `$DIR/meta.json` (keep the simulator ones), e.g.

```json
"device-wifi": { "device": "iPhone <model>, iOS <version>", "mode": "profile", "network": "wifi", "history": 50 },
"device-lte":  { "device": "iPhone <model>, iOS <version>", "mode": "profile", "network": "NLC LTE", "history": 50 },
"device-3g":   { "device": "iPhone <model>, iOS <version>", "mode": "profile", "network": "NLC 3G", "history": 50 }
```

```bash
npm run eval:timing:summary -- "$DIR"
```

Then delete the timing user when done: `node eval/timing/seed.mjs --cleanup`.

## Session log

| # | Label | Date/time | On record? | Turns answered | What happened (crash, drop, no reply, retry) |
|---|---|---|---|---|---|
| 1 | device-wifi | | yes | /3 | |
| 2 | device-wifi | | yes | /3 | |
| 3 | device-wifi | | yes | /3 | |
| 4 | device-wifi | | no | /3 | |
| 5 | device-wifi | | no | /3 | |
| 6 | device-lte | | no | /3 | |
| 7 | device-lte | | no | /3 | |
| 8 | device-lte | | no | /3 | |
| 9 | device-3g | | no | /3 | |
| 10 | device-3g | | no | /3 | |

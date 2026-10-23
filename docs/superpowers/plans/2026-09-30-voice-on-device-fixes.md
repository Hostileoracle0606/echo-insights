# Voice On-Device Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a voice session work on a real iPhone: Lumen is audible, joins without a 5 s stall, never waits forever on a tool call, keeps model "thinking" out of the user's transcript, and saves transcripts.

**Architecture:** One native `AVAudioEngine` (Swift, in the Runner app) replaces `record` and `just_audio`: it records the mic with Apple voice processing and plays Lumen's PCM through a player node on the *same* engine, so echo cancellation hears Lumen and playback needs no stream to open. Dart keeps its existing seams (`MicCapture`, `PcmPlayer`, `AudioOutput`); only their backends change. The smaller fixes sit where each fault is: tool timeouts and text-part routing in `GeminiLiveClient`, token freshness in the Supabase providers, and extraction scheduling in `JournalNotifier`.

**Tech Stack:** Flutter 3.41 / Dart 3, Riverpod, Swift + AVFoundation (iOS 16+), Flutter platform channels, Gemini Live WebSocket, Supabase (Postgres + pgTAP).

**Spec:** The on-device findings below (from the 2026-09-29 iPhone log and code reading), plus `docs/voice-session-lifecycle-plan.md` for the session lifecycle this builds on.

## Findings this plan implements

| Id | Finding | Evidence |
| --- | --- | --- |
| A | Lumen is silent and every join waits ~5 s: `PcmPlayer.init()` awaits `just_audio` `setAudioSource` on an empty live stream, which can't resolve before audio arrives, and audio is only fed after init. Per-chunk WAV headers would also break continuous playback. `record`'s voice processing runs on its own engine, so echo cancellation never hears Lumen. | Device log: `player unavailable … TimeoutException after 0:00:05`, endless `auou/vpio … render err: -1`; `lib/audio/pcm_player.dart`, `record_ios` `RecorderStreamDelegate.swift:128` |
| B | A tool handler that never completes leaves Gemini waiting forever ("stops responding"). Errors are answered; hangs are not. | `lib/services/gemini_live_client.dart:427-429`, `_retrieveMemory` has no timeout |
| C | `modelTurn` text parts (the model's thinking, since responses are AUDIO) are routed to the **user** transcript callback. | `lib/services/gemini_live_client.dart:443-445` (since `62f6003`) |
| D | Extraction is serialized and runs a model call for Lumen's turns too; no timing logs exist to see which step dominates. | `lib/providers/journal_provider.dart:470-473, 563-599` |
| E | `conversation_turns` migration never applied: every transcript save fails. | Device log: `PGRST205 … conversation_turns` |
| F | First credential fetch at launch races Supabase's session refresh and gets 401. | Device log: `fetch failed: … signed-in session is no longer valid` |

## Global Constraints

- iOS deployment target stays **16.0** (`ios/Podfile`); any newer API needs `#available`.
- Gemini Live audio: mic **16 kHz PCM16 mono** in, Lumen **24 kHz PCM16 mono** out (`geminiOutputSampleRate = 24000`).
- No new pub dependencies. Task 8 removes `record`, `just_audio` and `audio_session`.
- Live Supabase project is **`bjoevzvsdlhlcjywpyfx`**; never push to `giyjrvixpbfnourkpsen` (decoy). Pin `--project-ref` / `--linked` after checking.
- Running `flutter test` regenerates `docs/assets/*.png`, and `flutter pub get` may drift `pubspec.lock`: never commit either unless the task changes dependencies (Task 8 does, legitimately). Restore with `git checkout -- docs/assets`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Verification commands: `flutter analyze` (must be clean) and `flutter test` (all pass) after every task.

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `lib/services/gemini_live_client.dart` | Modify | Tool-call timeout (B); drop `modelTurn` text parts (C) |
| `lib/services/fresh_access_token.dart` | Create | Pure helper: return a token that won't be rejected, refreshing if stale (F) |
| `lib/providers/supabase_provider.dart` | Modify | Use `freshAccessToken` for runtime + extraction services (F) |
| `ios/Runner/VoiceEngineDSP.swift` | Create | Pure sample conversion: PCM16→float, resample, mic tap→16 kHz PCM16 (A) |
| `ios/Runner/VoiceEnginePlugin.swift` | Create | One `AVAudioEngine`: session, voice processing, player node, mic tap, channels (A) |
| `ios/Runner/AppDelegate.swift` | Modify | Register `VoiceEnginePlugin` (A) |
| `ios/RunnerTests/VoiceEngineDSPTests.swift` | Create | XCTest for `VoiceEngineDSP` (A) |
| `lib/audio/voice_engine.dart` | Create | Dart bindings for the native engine's channels (A) |
| `lib/audio/pcm_player.dart` | Modify | New sample-oriented `PcmAudioBackend`; `VoiceEnginePlayback`; delete just_audio code (A) |
| `lib/audio/pcm_capture.dart` | Modify | Replace `PcmCapture` (record) with `EngineMicCapture` (A) |
| `lib/audio/audio_session_config.dart` | Delete | Session is configured natively now (A) |
| `lib/providers/voice_services_provider.dart`, `lib/providers/journal_provider.dart` | Modify | Wire engine-backed player/mic; drop Dart session config (A); extraction seams + skip + timing (D) |
| `lib/logic/conversation_policy.dart` | Modify | `extractAssistantTurns` switch (D) |
| `lib/services/retrieve_memory_service.dart` | Modify | `retrieveMemoryServiceProvider` seam (D) |
| `integration_test/mic_capture_probe_test.dart` | Modify | Probe the engine's mic + playback on device (A) |
| `pubspec.yaml`, `pubspec.lock` | Modify | Remove `record`, `just_audio`, `audio_session` (A) |

Task order: **1 (B), 2 (C), 3 (F), 4 (E)** are small and independent. **5 → 6 → 7 → 8 (A)** must run in order. **9 (D)** after 8. **10** is the on-device check.

---

### Task 1: Tool calls are always answered (B)

**Files:**
- Modify: `lib/services/gemini_live_client.dart:102-113` (constructor), `:415-433` (toolCall dispatch)
- Test: `test/gemini_live_client_test.dart`

**Interfaces:**
- Produces: `GeminiLiveClient({..., Duration toolTimeout = const Duration(seconds: 4)})`. Log line `[voice][client] toolCall <name> answered in <ms>ms` / `… timed out after <ms>ms — answering empty`.

- [ ] **Step 1: Write the failing tests** (append to `test/gemini_live_client_test.dart`; add imports `package:fake_async/fake_async.dart` and `support/fake_live_socket.dart`)

```dart
  group('tool calls', () {
    List<(String, Object?)> toolResponses(FakeLiveSocket socket) => [
          for (final message in socket.sent)
            if (message['tool_response'] != null)
              for (final r in (message['tool_response']
                  as Map)['function_responses'] as List)
                ((r as Map)['id'] as String, (r['response'] as Map)['output']),
        ];

    Map<String, dynamic> toolCall(String id) => {
          'toolCall': {
            'functionCalls': [
              {'id': id, 'name': 'get_relevant_memory', 'args': {'query': 'Priya'}},
            ],
          },
        };

    (GeminiLiveClient, FakeLiveSocket Function()) connectedClient(
      FakeAsync async,
      OnToolCall handler,
    ) {
      FakeLiveSocket? socket;
      final client = GeminiLiveClient(
        sessionToken: 't',
        model: 'm',
        systemInstruction: 's',
        voice: 'Aoede',
        tools: const [],
        toolTimeout: const Duration(seconds: 4),
        channelFactory: (uri) => socket = FakeLiveSocket(uri),
      )..onToolCall = handler;
      client.connect();
      async.flushMicrotasks();
      socket!.serverSends({'setupComplete': <String, dynamic>{}});
      async.flushMicrotasks();
      return (client, () => socket!);
    }

    test('a tool that never answers is answered empty at the timeout', () {
      fakeAsync((async) {
        final (_, socket) = connectedClient(
          async,
          (name, args) => Completer<Map<String, dynamic>>().future,
        );
        socket().serverSends(toolCall('call-1'));
        async.elapse(const Duration(seconds: 3));
        expect(toolResponses(socket()), isEmpty, reason: 'still in time');

        async.elapse(const Duration(seconds: 1));
        expect(toolResponses(socket()), [('call-1', <String, dynamic>{})]);
      });
    });

    test('a tool that answers in time is answered with its result, once', () {
      fakeAsync((async) {
        final (_, socket) = connectedClient(async, (name, args) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return {'context': 'Priya climbs'};
        });
        socket().serverSends(toolCall('call-2'));
        async.elapse(const Duration(seconds: 10));
        expect(toolResponses(socket()), [
          ('call-2', {'context': 'Priya climbs'}),
        ]);
      });
    });

    test('a tool that throws is answered empty straight away', () {
      fakeAsync((async) {
        final (_, socket) = connectedClient(
          async,
          (name, args) async => throw StateError('network'),
        );
        socket().serverSends(toolCall('call-3'));
        async.flushMicrotasks();
        expect(toolResponses(socket()), [('call-3', <String, dynamic>{})]);
      });
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/gemini_live_client_test.dart`
Expected: FAIL to compile: `No named parameter with the name 'toolTimeout'`.

- [ ] **Step 3: Implement**

Constructor (next to `channelFactory`):

```dart
    LiveChannelFactory? channelFactory,
    this.toolTimeout = const Duration(seconds: 4),
  })  : _resumptionHandle = resumptionHandle,
```

Field (with the other public fields):

```dart
  /// Gemini waits for an answer to every tool call before it continues, so a
  /// handler that hangs (a stalled network call) would silence Lumen for
  /// good. Past this, the call is answered with an empty result.
  final Duration toolTimeout;
```

Replace the dispatch body in the `toolCall` branch:

```dart
        final handler = onToolCall;
        final clock = Stopwatch()..start();
        final Future<Map<String, dynamic>> pending = handler == null
            ? Future.value(const <String, dynamic>{})
            : handler(name, args);
        pending.timeout(toolTimeout).then((result) {
          vlog('client',
              'toolCall $name answered in ${clock.elapsedMilliseconds}ms');
          respondToTool(id, result);
        }).catchError((Object error) {
          vlog('client',
              'toolCall $name ${error is TimeoutException ? 'timed out' : 'failed'} '
              'after ${clock.elapsedMilliseconds}ms — answering empty');
          respondToTool(id, const {});
        });
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/gemini_live_client_test.dart && flutter analyze`
Expected: all pass; no issues.

- [ ] **Step 5: Commit**

```bash
git add lib/services/gemini_live_client.dart test/gemini_live_client_test.dart
git commit -m "fix(voice): answer every tool call, empty after a 4s timeout

Gemini blocks until each tool call is answered; a hung memory lookup
silenced Lumen for the rest of the session.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Model text parts never become user speech (C)

**Files:**
- Modify: `lib/services/gemini_live_client.dart:439-446` (modelTurn parts loop)
- Test: `test/gemini_live_client_test.dart`

**Interfaces:**
- Produces: `onTranscript` receives **only** `inputTranscription`; `onAgentTranscript` only `outputTranscription`. Log line `[voice][client] gemini → model text part dropped (thought)`.

- [ ] **Step 1: Write the failing test**

```dart
  test('model text parts (thinking) reach neither transcript', () {
    final client = makeClient();
    final user = <String>[];
    final agent = <String>[];
    client
      ..onTranscript = (text, isFinal) {
        user.add(text);
      }
      ..onAgentTranscript = (text, isFinal) {
        agent.add(text);
      };

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'modelTurn': {
          'parts': [
            {'text': '**Planning** Ask about Priya.', 'thought': true},
            {'text': 'stray text without a thought flag'},
          ],
        },
      },
    }));

    expect(user, isEmpty, reason: "the model's words are never the user's");
    expect(agent, isEmpty, reason: 'Lumen speaks via outputTranscription');
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/gemini_live_client_test.dart --plain-name "model text parts"`
Expected: FAIL: `user` contains both strings.

- [ ] **Step 3: Implement** (replace the `if (p.containsKey('text'))` block)

```dart
        // Responses are AUDIO: Lumen's words arrive as outputTranscription.
        // Text parts here are the model's thinking — never the user's
        // speech (they used to be routed to onTranscript) and never shown.
        if (p.containsKey('text')) {
          vlog(
            'client',
            'gemini → model text part dropped'
                '${p['thought'] == true ? ' (thought)' : ''}',
          );
        }
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/gemini_live_client_test.dart && flutter analyze`
Expected: all pass; no issues.

- [ ] **Step 5: Commit**

```bash
git add lib/services/gemini_live_client.dart test/gemini_live_client_test.dart
git commit -m "fix(voice): keep the model's text parts out of the user transcript

With AUDIO responses, modelTurn text parts are the model's thinking;
they were routed to onTranscript and could appear as the user's words.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Requests never go out with a stale login token (F)

**Files:**
- Create: `lib/services/fresh_access_token.dart`
- Modify: `lib/providers/supabase_provider.dart:23-37`
- Test: `test/fresh_access_token_test.dart`

**Interfaces:**
- Produces: `typedef TokenSnapshot = ({String accessToken, int? expiresAt});` and
  `Future<String?> freshAccessToken({required TokenSnapshot? Function() current, required Future<TokenSnapshot?> Function() refresh, Duration margin = const Duration(seconds: 30), DateTime Function()? now})`.

- [ ] **Step 1: Write the failing tests** (`test/fresh_access_token_test.dart`)

```dart
// At launch Supabase refreshes the session in the background; a request
// made meanwhile carried the expired token and got 401 ("the signed-in
// session is no longer valid"). The token is refreshed first when stale.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/fresh_access_token.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 12);
  int epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
  var refreshes = 0;

  Future<String?> token(
    TokenSnapshot? current, {
    TokenSnapshot? refreshed,
    bool refreshThrows = false,
  }) {
    refreshes = 0;
    return freshAccessToken(
      current: () => current,
      refresh: () async {
        refreshes += 1;
        if (refreshThrows) throw StateError('offline');
        return refreshed;
      },
      now: () => now,
    );
  }

  test('a token valid past the margin is used as is', () async {
    final valid = (accessToken: 'a', expiresAt: epoch(now.add(const Duration(minutes: 10))));
    expect(await token(valid), 'a');
    expect(refreshes, 0);
  });

  test('an expired token is refreshed first', () async {
    final expired = (accessToken: 'old', expiresAt: epoch(now.subtract(const Duration(minutes: 1))));
    final fresh = (accessToken: 'new', expiresAt: epoch(now.add(const Duration(hours: 1))));
    expect(await token(expired, refreshed: fresh), 'new');
    expect(refreshes, 1);
  });

  test('a token about to expire counts as stale', () async {
    final closing = (accessToken: 'old', expiresAt: epoch(now.add(const Duration(seconds: 10))));
    final fresh = (accessToken: 'new', expiresAt: epoch(now.add(const Duration(hours: 1))));
    expect(await token(closing, refreshed: fresh), 'new');
  });

  test('a failed refresh falls back to the current token', () async {
    final expired = (accessToken: 'old', expiresAt: epoch(now.subtract(const Duration(minutes: 1))));
    expect(await token(expired, refreshThrows: true), 'old');
  });

  test('signed out: no token and no refresh', () async {
    expect(await token(null), isNull);
    expect(refreshes, 0);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/fresh_access_token_test.dart`
Expected: FAIL: `lib/services/fresh_access_token.dart` not found.

- [ ] **Step 3: Implement** (`lib/services/fresh_access_token.dart`)

```dart
/// The access token and its expiry (seconds since the epoch), as Supabase
/// reports them. A plain record so the rule below is testable without
/// building a Supabase session.
typedef TokenSnapshot = ({String accessToken, int? expiresAt});

/// Returns an access token the runtime won't reject. At launch Supabase
/// refreshes the session in the background; a token that has expired, or
/// is within [margin] of expiring, is refreshed first. If the refresh
/// fails, the current token is returned and the server decides.
Future<String?> freshAccessToken({
  required TokenSnapshot? Function() current,
  required Future<TokenSnapshot?> Function() refresh,
  Duration margin = const Duration(seconds: 30),
  DateTime Function()? now,
}) async {
  final session = current();
  if (session == null) return null;
  final expiresAt = session.expiresAt;
  final stale = expiresAt == null ||
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true)
          .isBefore((now ?? DateTime.now)().toUtc().add(margin));
  if (!stale) return session.accessToken;
  try {
    return (await refresh())?.accessToken ?? session.accessToken;
  } catch (_) {
    return session.accessToken;
  }
}
```

In `lib/providers/supabase_provider.dart` add the import `../services/fresh_access_token.dart`, then:

```dart
TokenSnapshot? _snapshot(Session? session) => session == null
    ? null
    : (accessToken: session.accessToken, expiresAt: session.expiresAt);

Future<String?> _accessToken(SupabaseClient client) => freshAccessToken(
      current: () => _snapshot(client.auth.currentSession),
      refresh: () async => _snapshot((await client.auth.refreshSession()).session),
    );
```

and in both `notebookRuntimeServiceProvider` and `extractGraphServiceProvider`:

```dart
    accessTokenProvider: () => _accessToken(client),
```

- [ ] **Step 4: Run tests**

Run: `flutter test && flutter analyze`
Expected: all pass (including `live_credentials_test.dart`); no issues. `git checkout -- docs/assets`.

- [ ] **Step 5: Commit**

```bash
git add lib/services/fresh_access_token.dart lib/providers/supabase_provider.dart test/fresh_access_token_test.dart
git commit -m "fix(auth): refresh a stale login token before calling the runtime

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Apply the `conversation_turns` migration (E)

This changes the **live database**. Run it only after the user approves in chat.

**Files:**
- Uses: `supabase/migrations/20260928000000_conversation_turns.sql`, `supabase/tests/database/` (pgTAP)

- [ ] **Step 1: Run the pgTAP tests locally, if Docker is running**

Run: `supabase test db`
Expected: all pass. If Docker isn't running, note it and continue: the tests already ran in Phase 3.

- [ ] **Step 2: Preflight: confirm the target project**

```bash
supabase projects list | grep bjoevzvsdlhlcjywpyfx
supabase link --project-ref bjoevzvsdlhlcjywpyfx
supabase migration list --linked
```
Expected: `bjoevzvsdlhlcjywpyfx` listed and linked; `20260928000000` shown as **local only** (not on remote). Stop if the linked ref is anything else.

- [ ] **Step 3: Dry run, then push**

```bash
supabase db push --linked --dry-run
supabase db push --linked
```
Expected: the dry run lists exactly `20260928000000_conversation_turns.sql`; the push applies it.

- [ ] **Step 4: Verify from the app**

Open a notebook on the simulator or device. Expected: no `saved transcript unavailable … PGRST205` line. After one exchange, reopening the notebook shows the earlier turns.

Nothing to commit: the migration file is already on `main`.

---

### Task 5: Native voice engine (A, part 1 of 4)

**Files:**
- Create: `ios/Runner/VoiceEngineDSP.swift`, `ios/Runner/VoiceEnginePlugin.swift`, `ios/RunnerTests/VoiceEngineDSPTests.swift`
- Modify: `ios/Runner/AppDelegate.swift`, `ios/Runner.xcodeproj/project.pbxproj` (via the xcodeproj gem)

**Interfaces:**
- Produces channels, consumed by Task 6:
  - `MethodChannel('lumen/voice_engine')`: `prepare` → null; `hasMicPermission` → bool; `requestMicPermission` → bool; `schedule` `{pcm: Uint8List, sampleRate: int}` → null; `stopPlayback` → null. Errors come back as `PlatformException(code: 'voice_engine')`.
  - `EventChannel('lumen/voice_engine/mic')`: while listened to, emits `Uint8List` chunks of 16 kHz PCM16 mono (≈100 ms).

- [ ] **Step 1: Write the failing XCTest** (`ios/RunnerTests/VoiceEngineDSPTests.swift`)

```swift
import AVFoundation
import XCTest
@testable import Runner

final class VoiceEngineDSPTests: XCTestCase {
  func testPCM16BecomesFloatInRange() {
    let samples: [Int16] = [0, 16384, -32768, 32767]
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let buffer = VoiceEngineDSP.floatBuffer(fromPCM16: data, sampleRate: 24_000)!
    XCTAssertEqual(buffer.frameLength, 4)
    XCTAssertEqual(buffer.format.sampleRate, 24_000)
    let out = buffer.floatChannelData![0]
    XCTAssertEqual(out[0], 0)
    XCTAssertEqual(out[1], 0.5, accuracy: 1e-4)
    XCTAssertEqual(out[2], -1)
    XCTAssertEqual(out[3], 1, accuracy: 1e-4)
  }

  func testEmptyPCMIsNothingToSchedule() {
    XCTAssertNil(VoiceEngineDSP.floatBuffer(fromPCM16: Data(), sampleRate: 24_000))
  }

  func testResamplesToThePlaybackRate() {
    let tone = [Int16](repeating: 8192, count: 1600) // 100 ms at 16 kHz
    let data = tone.withUnsafeBufferPointer { Data(buffer: $0) }
    let input = VoiceEngineDSP.floatBuffer(fromPCM16: data, sampleRate: 16_000)!
    let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let converter = AVAudioConverter(from: input.format, to: target)!
    let out = VoiceEngineDSP.convert(input, with: converter, to: target)!
    XCTAssertEqual(Double(out.frameLength), 2400, accuracy: 48) // 100 ms at 24 kHz
  }

  func testMicChunkIs16kHzPCM16FromTheFirstChannel() {
    // 100 ms of a 48 kHz two-channel tap, as voice processing may report it.
    let tapFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let tap = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 4800)!
    tap.frameLength = 4800
    for i in 0..<4800 {
      tap.floatChannelData![0][i] = 0.25
      tap.floatChannelData![1][i] = -0.9
    }
    let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let output = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: mono, to: output)!

    let chunk = VoiceEngineDSP.micChunk(
      from: tap, monoFormat: mono, converter: converter, output: output)!

    XCTAssertEqual(Double(chunk.count), 3200, accuracy: 64) // ~1600 samples × 2 B
    let middle = chunk.withUnsafeBytes {
      $0.load(fromByteOffset: (chunk.count / 2) & ~1, as: Int16.self)
    }
    XCTAssertEqual(Double(middle) / 32768, 0.25, accuracy: 0.02, "channel 0 carries the voice")
  }
}
```

- [ ] **Step 2: Add the files to the Xcode targets, then run to verify failure**

```bash
cat > ios/Runner/VoiceEngineDSP.swift <<'EOF'
import AVFoundation
EOF
cat > ios/Runner/VoiceEnginePlugin.swift <<'EOF'
import Flutter
EOF
ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("ios/Runner.xcodeproj")
runner = project.targets.find { |t| t.name == "Runner" }
tests = project.targets.find { |t| t.name == "RunnerTests" }
app = project.main_group["Runner"]
runner.add_file_references(%w[VoiceEngineDSP.swift VoiceEnginePlugin.swift].map { |f| app.new_reference(f) })
tests.add_file_references([project.main_group["RunnerTests"].new_reference("VoiceEngineDSPTests.swift")])
project.save'
flutter build ios --simulator --debug
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RunnerTests 2>&1 | tail -20
```
Expected: FAIL to compile: `cannot find 'VoiceEngineDSP' in scope`. The `xcodeproj` gem ships with CocoaPods; if `require` fails, run `gem install xcodeproj`.

- [ ] **Step 3: Implement `VoiceEngineDSP.swift`**

```swift
import AVFoundation

/// Sample conversions for the voice engine. Pure, so they can be unit-tested
/// without an audio session.
enum VoiceEngineDSP {
  /// PCM16 little-endian mono → a float mono buffer at `sampleRate`.
  static func floatBuffer(fromPCM16 data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
    let frames = data.count / 2
    guard frames > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let out = buffer.floatChannelData![0]
    data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<frames { out[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
    }
    return buffer
  }

  /// Converts `buffer` into a new buffer of `format`. The converter keeps its
  /// state between calls, so streaming audio resamples without seams.
  static func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    return status == .error ? nil : out
  }

  /// A mic tap buffer (hardware rate, any channel count) → 16 kHz PCM16 mono
  /// bytes. Voice processing may report several input channels; the first
  /// carries the processed voice.
  static func micChunk(
    from buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat,
    converter: AVAudioConverter, output: AVAudioFormat
  ) -> Data? {
    guard let source = buffer.floatChannelData,
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
    else { return nil }
    mono.frameLength = buffer.frameLength
    mono.floatChannelData![0].update(from: source[0], count: Int(buffer.frameLength))
    guard let out = convert(mono, with: converter, to: output), out.frameLength > 0 else {
      return nil
    }
    return Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
  }
}
```

- [ ] **Step 4: Implement `VoiceEnginePlugin.swift`**

```swift
import AVFoundation
import Flutter

/// One audio engine for the whole voice session. The mic (with Apple's voice
/// processing: echo cancellation, gain, noise suppression) and Lumen's voice
/// share it, so the echo canceller hears exactly what the speaker plays, and
/// playback is a queue of samples with nothing to open or wait on. Replaces
/// `record` (capture) and `just_audio` (playback).
final class VoiceEnginePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VoiceEnginePlugin()
    let methods = FlutterMethodChannel(
      name: "lumen/voice_engine", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    FlutterEventChannel(name: "lumen/voice_engine/mic", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  /// Lumen's voice as scheduled: Gemini's 24 kHz mono, float for the mixer.
  private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
  /// What Gemini expects from the mic.
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
  private var attached = false
  private var voiceProcessing = false
  private var micSink: FlutterEventSink?
  private var playbackConverters: [Double: AVAudioConverter] = [:]

  static var micPermissionGranted: Bool {
    AVAudioSession.sharedInstance().recordPermission == .granted
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "prepare":
        try prepare()
        result(nil)
      case "hasMicPermission":
        result(Self.micPermissionGranted)
      case "requestMicPermission":
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async { result(granted) }
        }
      case "schedule":
        guard let args = call.arguments as? [String: Any],
          let pcm = args["pcm"] as? FlutterStandardTypedData,
          let rate = args["sampleRate"] as? NSNumber
        else {
          result(FlutterError(code: "voice_engine", message: "bad schedule args", details: nil))
          return
        }
        try schedule(pcm16: pcm.data, sampleRate: rate.doubleValue)
        result(nil)
      case "stopPlayback":
        player.stop()
        if engine.isRunning { player.play() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "voice_engine", message: "\(error)", details: nil))
    }
  }

  /// Audio session + running engine with the player attached. Idempotent and
  /// cheap once running; also restarts an engine iOS stopped (a call, Siri).
  private func prepare() throws {
    if attached && engine.isRunning { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)
    if !attached {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
      attached = true
    }
    // Voice processing needs the mic. Turn it on only once permission
    // exists, so signing in never triggers the permission prompt.
    if Self.micPermissionGranted { try enableVoiceProcessing(restart: false) }
    engine.prepare()
    try engine.start()
    player.play()
  }

  /// Voice processing can only change while the engine is stopped.
  private func enableVoiceProcessing(restart: Bool) throws {
    guard !voiceProcessing else { return }
    let wasRunning = engine.isRunning
    if wasRunning { engine.stop() }
    try engine.inputNode.setVoiceProcessingEnabled(true)
    voiceProcessing = true
    if wasRunning && restart {
      engine.prepare()
      try engine.start()
      player.play()
    }
  }

  private func schedule(pcm16: Data, sampleRate: Double) throws {
    try prepare()
    guard let buffer = VoiceEngineDSP.floatBuffer(fromPCM16: pcm16, sampleRate: sampleRate)
    else { return }
    var playable = buffer
    if sampleRate != playbackFormat.sampleRate {
      let converter =
        playbackConverters[sampleRate]
        ?? AVAudioConverter(from: buffer.format, to: playbackFormat)!
      playbackConverters[sampleRate] = converter
      guard let converted = VoiceEngineDSP.convert(buffer, with: converter, to: playbackFormat)
      else { return }
      playable = converted
    }
    player.scheduleBuffer(playable, completionHandler: nil)
  }

  // MARK: mic stream

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    do {
      try prepare()
      try enableVoiceProcessing(restart: true)
      let input = engine.inputNode
      let inFormat = input.outputFormat(forBus: 0)
      guard let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
        let converter = AVAudioConverter(from: mono, to: micFormat)
      else {
        return FlutterError(code: "voice_engine", message: "unsupported mic format \(inFormat)", details: nil)
      }
      micSink = events
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 4800, format: inFormat) { [weak self] buffer, _ in
        guard let self,
          let chunk = VoiceEngineDSP.micChunk(
            from: buffer, monoFormat: mono, converter: converter, output: self.micFormat)
        else { return }
        DispatchQueue.main.async { self.micSink?(FlutterStandardTypedData(bytes: chunk)) }
      }
      return nil
    } catch {
      return FlutterError(code: "voice_engine", message: "\(error)", details: nil)
    }
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if voiceProcessing { engine.inputNode.removeTap(onBus: 0) }
    micSink = nil
    return nil
  }
}
```

Register it in `ios/Runner/AppDelegate.swift`:

```swift
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VoiceEnginePlugin") {
      VoiceEnginePlugin.register(with: registrar)
    }
  }
```

- [ ] **Step 5: Run the native tests**

Run: the `xcodebuild test … -only-testing:RunnerTests` command from Step 2.
Expected: `Test Suite 'VoiceEngineDSPTests' passed`, 4 tests. Also `flutter test` (no Dart changes yet) still passes.

- [ ] **Step 6: Commit**

```bash
git add ios/Runner/VoiceEngineDSP.swift ios/Runner/VoiceEnginePlugin.swift ios/Runner/AppDelegate.swift ios/RunnerTests/VoiceEngineDSPTests.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): one native audio engine for the mic and Lumen's voice

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Dart bindings for the engine (A, part 2 of 4)

**Files:**
- Create: `lib/audio/voice_engine.dart`
- Test: `test/voice_engine_test.dart`

**Interfaces:**
- Consumes: the channels from Task 5.
- Produces: `class VoiceEngine { VoiceEngine({MethodChannel? methods, EventChannel? mic}); static final VoiceEngine instance; Future<void> prepare(); Future<bool> hasMicPermission(); Future<bool> requestMicPermission(); Future<void> schedule(Uint8List pcm16, int sampleRate); Future<void> stopPlayback(); Stream<Uint8List> micChunks(); }`

- [ ] **Step 1: Write the failing tests** (`test/voice_engine_test.dart`)

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/voice_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('lumen/voice_engine');
  const mic = EventChannel('lumen/voice_engine/mic');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'hasMicPermission' => true,
        'requestMicPermission' => false,
        _ => null,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(mic, null);
  });

  test('schedule sends raw PCM and its rate — no WAV header', () async {
    await VoiceEngine().schedule(Uint8List.fromList([1, 2, 3, 4]), 24000);
    expect(calls.single.method, 'schedule');
    expect(calls.single.arguments, {
      'pcm': Uint8List.fromList([1, 2, 3, 4]),
      'sampleRate': 24000,
    });
  });

  test('prepare and stopPlayback are plain calls', () async {
    final engine = VoiceEngine();
    await engine.prepare();
    await engine.stopPlayback();
    expect(calls.map((c) => c.method), ['prepare', 'stopPlayback']);
  });

  test('permission answers come from the native side', () async {
    final engine = VoiceEngine();
    expect(await engine.hasMicPermission(), isTrue);
    expect(await engine.requestMicPermission(), isFalse);
  });

  test('mic chunks stream while listened to and stop on cancel', () async {
    var cancelled = false;
    messenger.setMockStreamHandler(
      mic,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events.success(Uint8List.fromList([7, 7]));
        },
        onCancel: (arguments) => cancelled = true,
      ),
    );
    final chunks = <Uint8List>[];
    final sub = VoiceEngine().micChunks().listen(chunks.add);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(chunks, [
      [7, 7],
    ]);
    expect(cancelled, isTrue);
  });

  test('a native failure surfaces as a PlatformException', () async {
    messenger.setMockMethodCallHandler(
      methods,
      (_) async => throw PlatformException(code: 'voice_engine', message: 'no route'),
    );
    await expectLater(VoiceEngine().prepare(), throwsA(isA<PlatformException>()));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/voice_engine_test.dart`
Expected: FAIL: `voice_engine.dart` not found.

- [ ] **Step 3: Implement** (`lib/audio/voice_engine.dart`)

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart side of the native voice engine (ios/Runner/VoiceEnginePlugin.swift):
/// one AVAudioEngine that records the mic with Apple voice processing and
/// plays Lumen's voice, so echo cancellation hears what the speaker plays.
class VoiceEngine {
  VoiceEngine({MethodChannel? methods, EventChannel? mic})
      : _methods = methods ?? const MethodChannel('lumen/voice_engine'),
        _mic = mic ?? const EventChannel('lumen/voice_engine/mic');

  static final instance = VoiceEngine();

  final MethodChannel _methods;
  final EventChannel _mic;

  /// Audio session and running engine. Idempotent; also recovers an engine
  /// iOS stopped (a phone call, Siri).
  Future<void> prepare() => _methods.invokeMethod<void>('prepare');

  Future<bool> hasMicPermission() async =>
      await _methods.invokeMethod<bool>('hasMicPermission') ?? false;

  /// Shows the system prompt if the user hasn't answered yet.
  Future<bool> requestMicPermission() async =>
      await _methods.invokeMethod<bool>('requestMicPermission') ?? false;

  /// Queues one PCM16 mono chunk behind everything already queued. Platform
  /// messages are delivered in order, so chunks play in the order sent.
  Future<void> schedule(Uint8List pcm16, int sampleRate) => _methods
      .invokeMethod<void>('schedule', {'pcm': pcm16, 'sampleRate': sampleRate});

  /// Drops everything queued; the engine keeps running.
  Future<void> stopPlayback() => _methods.invokeMethod<void>('stopPlayback');

  /// 16 kHz PCM16 mono mic audio, while listened to.
  Stream<Uint8List> micChunks() =>
      _mic.receiveBroadcastStream().map((chunk) => chunk as Uint8List);
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/voice_engine_test.dart && flutter analyze`
Expected: 5 pass; no issues.

- [ ] **Step 5: Commit**

```bash
git add lib/audio/voice_engine.dart test/voice_engine_test.dart
git commit -m "feat(audio): Dart bindings for the native voice engine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `PcmPlayer` plays through the engine (A, part 3 of 4)

**Files:**
- Modify: `lib/audio/pcm_player.dart` (whole file: the backend interface and `PcmPlayer` internals; keep the playback clock)
- Modify: `lib/providers/voice_services_provider.dart:19-23`
- Test: `test/pcm_player_test.dart` (rewrite the fake and the stream-specific tests), `test/journal_session_lifecycle_test.dart:53-65` (`_Backend`)

**Interfaces:**
- Consumes: `VoiceEngine` (Task 6).
- Produces:

```dart
abstract interface class PcmAudioBackend {
  Future<void> start();                                  // must not wait for audio
  Future<void> schedule(Uint8List pcm16, int sampleRate); // queue behind what's queued
  Future<void> stop();                                   // drop queued audio, stay ready
  Future<void> dispose();
}
class VoiceEnginePlayback implements PcmAudioBackend { VoiceEnginePlayback(VoiceEngine engine); }
```

`PcmPlayer`'s public API is unchanged: `init()`, `feed(pcm16, {sampleRate, audible})`, `flush()`, `dispose()`, `isDisposed`, `speaking`, `remaining`. The default backend becomes `VoiceEnginePlayback(VoiceEngine.instance)`. `JustAudioPcmBackend`, `_PcmStreamAudioSource` and `prependWavHeader` are deleted.

- [ ] **Step 1: Rewrite the tests** (`test/pcm_player_test.dart`: replace `_FakeBackend` and the stream/WAV tests; keep the `playback clock` group's bodies, which only use `feed`/`flush`/`speaking`/`remaining`)

```dart
class _FakeBackend implements PcmAudioBackend {
  final scheduled = <(List<int>, int)>[];
  int starts = 0;
  int stops = 0;
  int disposes = 0;

  @override
  Future<void> start() async => starts += 1;

  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async =>
      scheduled.add((pcm16.toList(), sampleRate));

  @override
  Future<void> stop() async => stops += 1;

  @override
  Future<void> dispose() async => disposes += 1;
}

void main() {
  test('init never waits for audio (the on-device 5 s timeout)', () async {
    final player = PcmPlayer(backend: _FakeBackend());
    // The just_audio backend blocked here until audio arrived, which
    // could only happen after init: it always hit the 5 s timeout.
    await player.init().timeout(const Duration(milliseconds: 100));
    expect(player.feed(Uint8List(4)), isTrue);
    await player.dispose();
  });

  test('feed before init is refused', () {
    final player = PcmPlayer(backend: _FakeBackend());
    expect(player.feed(Uint8List(4)), isFalse);
  });

  test('feed schedules the raw PCM at its rate, in order', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    player
      ..feed(Uint8List.fromList([1, 2]))
      ..feed(Uint8List.fromList([3, 4]), sampleRate: 16000);
    await Future<void>.delayed(Duration.zero);
    expect(backend.scheduled, [
      ([1, 2], 24000),
      ([3, 4], 16000),
    ]);
    await player.dispose();
  });

  test('muted audio runs the clock but never reaches the speaker', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    expect(player.feed(Uint8List(4800), audible: false), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(backend.scheduled, isEmpty);
    expect(player.speaking.value, isTrue);
    await player.dispose();
  });

  test('flush drops queued audio and stays ready', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    player.feed(Uint8List(48000));
    await player.flush();
    expect(backend.stops, 1);
    expect(player.speaking.value, isFalse);
    expect(player.feed(Uint8List(4)), isTrue);
    await player.dispose();
  });

  test('dispose is idempotent', () async {
    final backend = _FakeBackend();
    final player = PcmPlayer(backend: backend);
    await player.init();
    await Future.wait([player.dispose(), player.dispose()]);
    expect(player.isDisposed, isTrue);
    expect(backend.disposes, 1);
  });

  // group('playback clock', …) — keep the existing tests unchanged, apart
  // from constructing PcmPlayer(backend: _FakeBackend(), now: …). Delete
  // 'WAV header carries the chunk sample rate'.
}
```

In `test/journal_session_lifecycle_test.dart`, replace `_Backend` with:

```dart
class _Backend implements PcmAudioBackend {
  @override
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/pcm_player_test.dart`
Expected: FAIL to compile: `_FakeBackend` doesn't implement `setAudioStream`/`play`, and `start`/`schedule` aren't in the interface.

- [ ] **Step 3: Implement** (`lib/audio/pcm_player.dart`: replace everything above the playback-clock methods; keep `_advanceClock`, `_onSilenceDue`, `_resetClock` exactly as they are)

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../logic/voice_log.dart';
import 'voice_engine.dart';

/// Gemini Live's native-audio output rate (`audio/pcm;rate=24000`).
const int geminiOutputSampleRate = 24000;

/// Where scheduled PCM goes. The app plays through the native voice engine;
/// tests use a fake.
abstract interface class PcmAudioBackend {
  /// Readies the speaker. Must never wait for audio to arrive.
  Future<void> start();

  /// Queues one PCM16 mono chunk behind everything already queued.
  Future<void> schedule(Uint8List pcm16, int sampleRate);

  /// Drops everything queued; the backend stays ready.
  Future<void> stop();

  Future<void> dispose();
}

/// Lumen's voice through the shared engine, so the mic's echo canceller
/// hears it.
class VoiceEnginePlayback implements PcmAudioBackend {
  VoiceEnginePlayback(this._engine);
  final VoiceEngine _engine;

  @override
  Future<void> start() => _engine.prepare();

  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) =>
      _engine.schedule(pcm16, sampleRate);

  @override
  Future<void> stop() => _engine.stopPlayback();

  // The engine is app-wide; a disposed player only silences what it queued.
  @override
  Future<void> dispose() => _engine.stopPlayback();
}

/// Plays agent PCM and keeps a playback clock: every accepted chunk extends
/// an estimated end-of-playback instant by its own duration, and [speaking]
/// is true until that passes (Gemini streams faster than real time).
class PcmPlayer {
  PcmPlayer({PcmAudioBackend? backend, Duration Function()? now})
      : _backend = backend ?? VoiceEnginePlayback(VoiceEngine.instance),
        _now = now ?? _monotonic();

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final PcmAudioBackend _backend;
  final Duration Function() _now;
  final ValueNotifier<bool> _speaking = ValueNotifier(false);
  Duration _tail = Duration.zero;
  Timer? _silenceTimer;
  bool _ready = false;
  bool _disposed = false;
  bool _disposedNotifier = false;
  Future<void>? _disposing;

  ValueListenable<bool> get speaking => _speaking;

  Duration get remaining {
    final left = _tail - _now();
    return left.isNegative ? Duration.zero : left;
  }

  bool get isDisposed => _disposed;

  Future<void> init() async {
    if (_disposed || _ready) return;
    await _backend.start();
    if (!_disposed) _ready = true;
  }

  /// Queues audio and advances the playback clock. With [audible] false
  /// (muted) the audio skips the speaker but still counts as Lumen talking.
  bool feed(
    Uint8List pcm16, {
    int sampleRate = geminiOutputSampleRate,
    bool audible = true,
  }) {
    if (!_ready || _disposed) return false;
    if (audible) {
      _backend.schedule(pcm16, sampleRate).catchError((Object error) {
        vlog('playback', 'schedule failed: $error');
      });
    }
    _advanceClock(pcm16.length, sampleRate);
    return true;
  }

  /// Stops what's queued (barge-in); the player stays ready.
  Future<void> flush() async {
    _resetClock();
    if (_disposed) return;
    await _backend.stop();
  }

  Future<void> dispose() {
    return _disposing ??= () async {
      _disposed = true;
      _ready = false;
      _resetClock();
      _disposedNotifier = true;
      _speaking.dispose();
      await _backend.dispose();
    }();
  }

  // _advanceClock, _onSilenceDue and _resetClock: unchanged.
}
```

In `lib/providers/voice_services_provider.dart`, drop the `audio_session_config.dart` import and the `prepare:` argument (the backend's `start()` prepares the engine):

```dart
final audioOutputProvider = Provider<AudioOutput>((ref) {
  final output = AudioOutput();
  ref.onDispose(output.stop);
  return output;
});
```

- [ ] **Step 4: Run tests**

Run: `flutter test && flutter analyze`
Expected: all pass. Fix any other reference to `JustAudioPcmBackend`, `setAudioStream` or `prependWavHeader` that analyze reports (`grep -rn "prependWavHeader\|JustAudioPcmBackend\|setAudioStream" lib test tool integration_test`). `git checkout -- docs/assets`.

- [ ] **Step 5: Commit**

```bash
git add lib/audio/pcm_player.dart lib/providers/voice_services_provider.dart test/pcm_player_test.dart test/journal_session_lifecycle_test.dart
git commit -m "fix(audio): play Lumen through the voice engine, not just_audio

PcmPlayer.init awaited just_audio's setAudioSource on an empty live
stream, which only resolves once audio arrives — after init. It timed
out after 5 s on every device, so Lumen was never heard and each join
waited 5 s. Samples are now queued on the native engine.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The mic goes through the engine; drop `record`, `just_audio`, `audio_session` (A, part 4 of 4)

**Files:**
- Modify: `lib/audio/pcm_capture.dart` (replace `PcmCapture` with `EngineMicCapture`)
- Modify: `lib/providers/journal_provider.dart:1224, 1237` (drop `configureVoiceAudioSession`), `:1803-1806` (`micCaptureFactoryProvider`)
- Delete: `lib/audio/audio_session_config.dart`
- Modify: `pubspec.yaml` (remove `record`, `just_audio`, `audio_session`), `pubspec.lock`
- Modify: `integration_test/mic_capture_probe_test.dart`
- Test: `test/engine_mic_capture_test.dart`

**Interfaces:**
- Consumes: `VoiceEngine` (Task 6).
- Produces: `class EngineMicCapture implements MicCapture { EngineMicCapture([VoiceEngine? engine]); }`. `MicCapture` is unchanged.

- [ ] **Step 1: Write the failing tests** (`test/engine_mic_capture_test.dart`)

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/voice_engine.dart';

class _FakeEngine extends VoiceEngine {
  _FakeEngine({this.granted = true, this.grantOnRequest = true});
  final bool granted;
  final bool grantOnRequest;
  int requests = 0;
  final mic = StreamController<Uint8List>.broadcast();

  @override
  Future<bool> hasMicPermission() async => granted;

  @override
  Future<bool> requestMicPermission() async {
    requests += 1;
    return grantOnRequest;
  }

  @override
  Stream<Uint8List> micChunks() => mic.stream;
}

void main() {
  test('forwards mic chunks in order', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    final got = <List<int>>[];
    await capture.start((pcm) => got.add(pcm.toList()));
    engine.mic
      ..add(Uint8List.fromList([1, 1]))
      ..add(Uint8List.fromList([2, 2]));
    await Future<void>.delayed(Duration.zero);
    expect(got, [
      [1, 1],
      [2, 2],
    ]);
    await capture.stop();
  });

  test('stop ends the stream (the native tap is removed)', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    await capture.start((_) {});
    expect(engine.mic.hasListener, isTrue);
    await capture.stop();
    expect(engine.mic.hasListener, isFalse);
  });

  test('starting again does not deliver chunks twice', () async {
    final engine = _FakeEngine();
    final capture = EngineMicCapture(engine);
    var count = 0;
    await capture.start((_) => count += 1);
    await capture.start((_) => count += 1);
    engine.mic.add(Uint8List(2));
    await Future<void>.delayed(Duration.zero);
    expect(count, 1);
    await capture.stop();
  });

  test('permission already granted: no prompt', () async {
    final engine = _FakeEngine();
    expect(await EngineMicCapture(engine).hasPermission(), isTrue);
    expect(engine.requests, 0);
  });

  test('permission not yet granted: prompts and returns the answer', () async {
    final engine = _FakeEngine(granted: false, grantOnRequest: false);
    expect(await EngineMicCapture(engine).hasPermission(), isFalse);
    expect(engine.requests, 1);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/engine_mic_capture_test.dart`
Expected: FAIL: `EngineMicCapture` isn't defined.

- [ ] **Step 3: Implement.** Replace `PcmCapture` in `lib/audio/pcm_capture.dart`: keep the `MicCapture` interface and swap the `record` import for `voice_engine.dart`.

```dart
/// The mic through the shared voice engine: 16 kHz PCM16 mono with Apple's
/// voice processing, whose echo canceller hears Lumen because Lumen plays
/// through the same engine.
class EngineMicCapture implements MicCapture {
  EngineMicCapture([VoiceEngine? engine])
      : _engine = engine ?? VoiceEngine.instance;

  final VoiceEngine _engine;
  StreamSubscription<Uint8List>? _sub;
  int _chunks = 0;

  @override
  Future<bool> hasPermission() async =>
      await _engine.hasMicPermission() || await _engine.requestMicPermission();

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    vlog('capture', 'starting (16 kHz PCM16 mono, voice processing, shared engine)');
    await _sub?.cancel();
    _chunks = 0;
    _sub = _engine.micChunks().listen(
      (pcm) {
        _chunks++;
        if (_chunks == 1 || _chunks % 100 == 0) {
          vlog('capture', 'mic chunk #$_chunks (${pcm.length} B)');
        }
        onChunk(pcm);
      },
      onError: (Object error) => vlog('capture', 'mic stream error: $error'),
    );
  }

  @override
  Future<void> stop() async {
    vlog('capture', 'stopping (delivered $_chunks chunks)');
    await _sub?.cancel();
    _sub = null;
  }
}
```

In `lib/providers/journal_provider.dart`:

```dart
final micCaptureFactoryProvider = Provider<MicCapture Function()>(
  (ref) => EngineMicCapture.new,
);
```

and in `_prepareLiveUnlocked` delete `final audioSessionReady = configureVoiceAudioSession();` (line 1224) and `await audioSessionReady;` (line 1237), plus the `audio_session_config.dart` import. The engine configures the session natively.

Then:

```bash
git rm lib/audio/audio_session_config.dart
sed -i '' '/^  record: /d; /^  just_audio: /d; /^  audio_session: /d' pubspec.yaml
flutter pub get
grep -rn "package:record\|package:just_audio\|package:audio_session\|configureVoiceAudioSession\|PcmCapture\b" lib test tool integration_test
```
Expected: the grep prints only `integration_test/mic_capture_probe_test.dart`, which is fixed next.

In `integration_test/mic_capture_probe_test.dart`, replace the `AudioSession` block and `PcmCapture()` with the engine (keep the probe's chunk/byte-rate/peak measurement code):

```dart
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/audio/voice_engine.dart';
// …
    // 1. The engine the app uses: session, voice processing, player node.
    await VoiceEngine.instance.prepare();
    debugPrintSynchronously('[probe] voice engine prepared');

    // 2. Playback must start at once (it used to time out after 5 s).
    final player = PcmPlayer();
    await player.init().timeout(const Duration(seconds: 1));
    player.feed(Uint8List(48000)); // 1 s of silence through the speaker path
    debugPrintSynchronously('[probe] playback ready and accepting audio');

    // 3. Mic capture through the same engine.
    final capture = EngineMicCapture();
    final permitted =
        await capture.hasPermission().timeout(const Duration(seconds: 15));
```

- [ ] **Step 4: Run tests**

Run: `flutter test && flutter analyze && flutter build ios --simulator --debug`
Expected: all pass; no issues; builds. `git checkout -- docs/assets`.

- [ ] **Step 5: Commit**

```bash
git add lib/audio/pcm_capture.dart lib/providers/journal_provider.dart test/engine_mic_capture_test.dart integration_test/mic_capture_probe_test.dart pubspec.yaml pubspec.lock
git commit -m "fix(audio): capture through the voice engine; drop record, just_audio, audio_session

record ran voice processing on its own engine (endless vpio render
errors) whose echo canceller could never hear Lumen's voice. Mic and
playback now share one engine.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Extraction timing, and no standalone model call for Lumen's turns (D)

**Behaviour change, to confirm with the user first:** Lumen's turns stop getting their own extraction model call. Their words already reach the extractor as `recentConversation` context on the user's next turn. The turn still commits a journal entry (with an empty graph patch), and the web app is unchanged. `extractAssistantTurns = true` restores today's behaviour.

**Files:**
- Modify: `lib/logic/conversation_policy.dart` (add `extractAssistantTurns`)
- Modify: `lib/services/retrieve_memory_service.dart` (add `retrieveMemoryServiceProvider`)
- Modify: `lib/providers/journal_provider.dart:470-473` (`_performEffect`), `:563-599` (`_runDurableExtraction` timing), `:601` (`_runCommit` timing), `:819-839` (`_retrieveMemory` uses the provider)
- Test: `test/journal_session_lifecycle_test.dart`

**Interfaces:**
- Produces: `const bool extractAssistantTurns = false;` and `final retrieveMemoryServiceProvider = Provider<RetrieveMemoryService>(…)`. Log lines `[voice][timing] extract <speaker> retrieve +<ms>ms`, `… model +<ms>ms`, `… commit +<ms>ms`, `… extract assistant turn skipped`.

- [ ] **Step 1: Write the failing test.** In `test/journal_session_lifecycle_test.dart`, add these fakes:

```dart
class _FakeExtractor implements ExtractGraphService {
  final texts = <String>[];

  @override
  Future<GraphPatch> extract({
    required String notebookId,
    required String turnId,
    required String extractorVersion,
    required String text,
    required JournalState state,
    required String mode,
    List<({Speaker role, String text})> recentConversation = const [],
    List<String> retrievedEntityIds = const [],
    FollowUp? answeringFollowUp,
    int tokenBudget = defaultExtractionTokenBudget,
    int maxRetries = 2,
  }) async {
    texts.add(text);
    return GraphPatch.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoMemory implements RetrieveMemoryService {
  @override
  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async =>
      MemoryRetrieval.empty;

  @override
  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async =>
      '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
```

Let commits succeed, so the queue keeps moving. In `_FakeCommits` add:

```dart
  int commits = 0;

  @override
  Future<CommitOutcome> commitNotebook({
    required String notebookId,
    required int expectedRevision,
    required String requestId,
    required NotebookChange change,
  }) async {
    commits += 1;
    return CommitCommitted(requestId: requestId, revision: expectedRevision + 1);
  }
```

and in `_FakeTurnJournal`:

```dart
  @override
  Future<void> persistPreparedCommit({
    required FinalizedTurn turn,
    required PreparedTurnCommit preparedCommit,
  }) async {}
```

In `_Harness`, keep the commits fake in a field and add the overrides:

```dart
  final extractor = _FakeExtractor();
  late final _FakeCommits commits;
  // in the constructor, before building the container:
  //   commits = _FakeCommits(state ?? JournalState.empty());
  // overrides:
      notebookCommitServiceProvider.overrideWithValue(commits),
      extractGraphServiceProvider.overrideWithValue(extractor),
      retrieveMemoryServiceProvider.overrideWithValue(_NoMemory()),
```

Then the test. Add the imports the fakes need (the file already imports `turn_journal_service.dart` for `PreparedTurnCommit` and `notebook_commit_service.dart`):

```dart
import 'package:lumen/models/follow_up.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/extraction_context.dart'; // defaultExtractionTokenBudget
import 'package:lumen/services/retrieve_memory_service.dart';
```

```dart
  test("Lumen's turns commit without a model call of their own", () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {'text': 'I finished the Atlas draft.', 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {
          'outputTranscription': {'text': 'How does it feel to be done?', 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });

    // Both turns commit (so the queue drained past Lumen's turn)…
    for (var i = 0; i < 100 && h.commits.commits < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(h.commits.commits, 2);
    // …but only the user's words were sent to the extractor.
    expect(h.extractor.texts, ['I finished the Atlas draft.']);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/journal_session_lifecycle_test.dart --plain-name "without a model call"`
Expected: FAIL: first to compile (`retrieveMemoryServiceProvider` isn't defined), then, once Step 3's provider exists but before the skip, with `texts` holding both lines.

- [ ] **Step 3: Implement**

`lib/logic/conversation_policy.dart`:

```dart
/// Lumen's own turns get no extraction model call: their words already
/// reach the extractor as context on the user's next turn, and a call of
/// their own mostly re-extracts what the user said while holding up the
/// queue. The turn still commits its journal entry.
const bool extractAssistantTurns = false;
```

`lib/services/retrieve_memory_service.dart` (add the `flutter_riverpod` and `../providers/supabase_provider.dart` imports):

```dart
/// Memory retrieval for extraction and the get_relevant_memory tool; tests
/// substitute a fake.
final retrieveMemoryServiceProvider = Provider<RetrieveMemoryService>(
  (ref) => RetrieveMemoryService(ref.watch(supabaseClientProvider)),
);
```

`lib/providers/journal_provider.dart`, in `_performEffect`:

```dart
      case StartDurableExtraction():
        final turn = _turnMachine.state.pending
            .where((t) => t.turnId == effect.key.turnId)
            .firstOrNull;
        if (!extractAssistantTurns && turn?.speaker == Speaker.assistant) {
          vlog('timing', 'extract assistant turn skipped');
          final patch = GraphPatch.empty();
          _lastPatches[effect.key.turnId] = patch;
          _dispatchTurn(DurableExtractionSucceeded(
            key: effect.key,
            payload: patch.toJson(),
          ));
          return;
        }
        await _runDurableExtraction(effect);
```

In `_runDurableExtraction`, switch retrieval to the provider and add timing:

```dart
    final clock = Stopwatch()..start();
    try {
      final retrieval = await ref.read(retrieveMemoryServiceProvider).retrieveResult(
            query: effect.transcript,
            notebookId: effect.key.notebookId,
            state: state,
          );
      vlog('timing', 'extract retrieve +${clock.elapsedMilliseconds}ms');
      // … existing extractService.extract(...) call unchanged …
      vlog('timing', 'extract model +${clock.elapsedMilliseconds}ms');
```

In `_runCommit`, wrap the `commitService.commitNotebook(...)` await:

```dart
      final commitClock = Stopwatch()..start();
      outcome = await commitService.commitNotebook(/* unchanged args */);
      vlog('timing', 'commit +${commitClock.elapsedMilliseconds}ms');
```

In `_retrieveMemory`, replace `RetrieveMemoryService(ref.read(supabaseClientProvider))` with `ref.read(retrieveMemoryServiceProvider)`.

- [ ] **Step 4: Run tests**

Run: `flutter test && flutter analyze`
Expected: all pass, including the existing `finalized turns from both speakers are saved once`. `git checkout -- docs/assets`.

- [ ] **Step 5: Commit**

```bash
git add lib/logic/conversation_policy.dart lib/services/retrieve_memory_service.dart lib/providers/journal_provider.dart test/journal_session_lifecycle_test.dart
git commit -m "perf(extraction): no model call for Lumen's turns; time each step

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Verify on the iPhone (A–F, plus the live-transcript measurement)

No code. The session needs a physical device: the Simulator can't prove audio.

- [ ] **Step 1: Run the device probe**

```bash
flutter devices   # note the iPhone id, e.g. 00008120-000A59D90C12601E
flutter test integration_test/mic_capture_probe_test.dart -d <iphone-id>
```
Expected: `[probe] playback ready` within 1 s; mic chunks at ≈32,000 B/s with a non-zero peak while you talk.

- [ ] **Step 2: Run the app on the device**

```bash
flutter run -d <iphone-id> --dart-define-from-file=<defines file with SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, NOTEBOOK_RUNTIME_URL>
```
Filter the Xcode console (or the `flutter run` output) by `[voice]`.

- [ ] **Step 3: Check each finding**

| Finding | Pass when |
| --- | --- |
| A | `app-level player ready` right after sign-in (no `TimeoutException`); no `render err: -1`; the greeting is **audible**; `[timing] playback ready` within ~1 s of `setup complete`; Lumen does not interrupt itself from its own voice on the speaker |
| B | Every `toolCall …` line is followed by `answered in …` or `timed out … answering empty`; Lumen still replies after a timeout |
| C | No model thinking shows in the dock; note the spacing of `gemini → user transcript` lines while you speak (the live-caption measurement) |
| D | `extract assistant turn skipped` per Lumen turn; note `retrieve` / `model` / `commit` ms per user turn |
| E | No `PGRST205`; reopening the notebook shows the conversation |
| F | No `fetch failed: … no longer valid` at launch |
| Stall | Hold a 6+ turn conversation; Lumen keeps responding |

- [ ] **Step 4: Report** the table with the measured numbers (join time from tap to `live`, extraction step times, transcript cadence). If live captions still arrive in bursts, the follow-up (on-device captions via iOS speech recognition) gets its own plan.

---

## Out of scope

- On-device live captions (iOS speech recognition): only if Task 10 shows Gemini's input transcription arrives in bursts.
- Provisional extraction (`provisionalExtraction = true`): faster entity previews, at one extra model call per utterance. Decide after Task 10's timings.
- Web app changes: the web keeps extracting Lumen's turns.

// LIVE backend probe (NOT part of the normal suite — no `_test.dart` suffix, so
// `flutter test` skips it). Records what Gemini Live does with a typed turn
// (`client_content`, `turn_complete: true`) in a session that streamed audio
// through realtime input, as LM-12's composer does:
//
//   1. Mic audio is streamed, then the mic pauses (`audioStreamEnd`).
//   2. A typed turn is sent. Does Lumen answer it?
//   3. A second typed turn is sent while the first answer is still being
//      generated. Does Gemini send `interrupted`, and a `turnComplete` for the
//      cut-off answer before the new answer's transcription starts?
//
// Run explicitly (the key comes from the environment or `.env`):
//
//   flutter test test/gemini_live_typed_turn_probe.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

import 'live_token_probe_helper.dart';

String _env(String key) {
  final fromEnvironment = Platform.environment[key];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final f = File('.env');
  if (!f.existsSync()) return '';
  for (final line in f.readAsLinesSync()) {
    if (line.startsWith('$key=')) {
      return line
          .substring(key.length + 1)
          .trim()
          .replaceAll('"', '')
          .replaceAll("'", '');
    }
  }
  return '';
}

/// One session: a typed turn after the mic pauses, then a second typed turn
/// that cuts the first answer off: while it is still being generated, or
/// once generated but (Gemini paces turnComplete to the audio) still playing.
Future<void> _probe({required bool afterGenerationComplete}) async {
  final key = _env('GEMINI_API_KEY');
  expect(key, isNotEmpty, reason: 'GEMINI_API_KEY missing');

  const model = 'gemini-3.1-flash-live-preview';
  final sessionToken = await requestLiveProbeToken(apiKey: key, model: model);
  final client = GeminiLiveClient(
    sessionToken: sessionToken,
    model: model,
    systemInstruction: 'You are a warm journaling companion.',
    voice: 'Aoede',
    tools: const [],
  );

  final clock = Stopwatch()..start();
  final log = <String>[];
  void note(String event) => log.add('${clock.elapsedMilliseconds}ms $event');

  // 1: first typed turn sent; 2: second sent, first answer's tail still
  // arriving; 3: the cut-off turn completed, so this is the answer to 2.
  var phase = 0;
  var audioInPhase = 0;
  var turnCompletes = 0;
  final answers = <int, StringBuffer>{
    1: StringBuffer(),
    2: StringBuffer(),
    3: StringBuffer(),
  };
  final done = Completer<void>();

  void sendTyped(String text) {
    phase += 1;
    audioInPhase = 0;
    note('→ client_content (typed turn $phase)');
    client.sendText(text);
  }

  void cutIn() => sendTyped('Sorry to cut in. What is two plus two? One word.');

  client
    ..onSetupComplete = () {
      note('setupComplete');
      // About a second of silence through realtime input, then the mic
      // pauses — the state the composer leaves the session in.
      for (var i = 0; i < 10; i++) {
        client.sendAudio(Uint8List(3200));
      }
      client.sendAudioStreamEnd();
      note('→ audioStreamEnd (mic paused)');
      sendTyped('Tell me, slowly and in at least eight sentences, about a '
          'lighthouse keeper on a stormy night.');
    }
    ..onTranscript = (t, f) {
      note('user transcript "$t" final=$f');
    }
    ..onAgentTranscript = (t, f) {
      final answer = answers[phase];
      if (answer != null && answer.isEmpty) {
        note('agent transcript (phase $phase)');
      }
      answer?.write(t);
    }
    ..onAudio = (_, __) {
      audioInPhase += 1;
      if (audioInPhase == 1) note('agent audio (phase $phase)');
      // Cut the first answer off while it is still being generated.
      if (!afterGenerationComplete && phase == 1 && audioInPhase == 3) {
        cutIn();
      }
    }
    ..onInterrupted = () {
      note('interrupted');
    }
    ..onGenerationComplete = () {
      note('generationComplete (phase $phase)');
      // Generated, but the answer is still "playing": Gemini paces its
      // turnComplete to the audio, so the turn is still open.
      if (afterGenerationComplete && phase == 1) {
        Timer(const Duration(milliseconds: 500), cutIn);
      }
    }
    ..onTurnComplete = () {
      turnCompletes += 1;
      note('turnComplete #$turnCompletes (phase $phase)');
      if (phase == 2) {
        phase = 3;
        audioInPhase = 0;
      } else if (phase == 3 && !done.isCompleted) {
        done.complete();
      }
    }
    ..onError = (e) {
      note('error $e');
      if (!done.isCompleted) done.completeError(e);
    };

  try {
    await client.connect();
    await done.future.timeout(const Duration(seconds: 60));
  } on TimeoutException {
    note('TIMEOUT');
  } finally {
    await client.close();
  }

  // ignore: avoid_print
  print([
    ...log,
    'answer 1 (${answers[1]!.length} chars): '
        '"${answers[1].toString().trim()}"',
    'first answer\'s tail after the cut-in (${answers[2]!.length} chars): '
        '"${answers[2].toString().trim()}"',
    'answer to the cut-in (${answers[3]!.length} chars): '
        '"${answers[3].toString().trim()}"',
  ].join('\n'));
  expect(answers[1].toString(), isNotEmpty,
      reason: 'the typed turn after the mic paused got no answer');
  expect(answers[3].toString(), isNotEmpty,
      reason: 'the typed turn sent over the first answer got no answer');
  expect(log.where((line) => line.endsWith(' interrupted')), hasLength(1),
      reason: 'the cut-off answer is reported as interrupted');
}

void main() {
  test('a typed turn cuts in while the answer is still being generated',
      () => _probe(afterGenerationComplete: false),
      timeout: const Timeout(Duration(seconds: 90)));

  test('a typed turn cuts in after generation, while the answer still plays',
      () => _probe(afterGenerationComplete: true),
      timeout: const Timeout(Duration(seconds: 90)));
}

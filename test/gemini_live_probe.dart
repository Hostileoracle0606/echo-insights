// LIVE backend probe (NOT part of the normal suite — no `_test.dart` suffix, so
// `flutter test` skips it). Drives the REAL GeminiLiveClient with a text turn
// (no mic) to isolate whether the voice failure is the backend session or the
// mic capture. Run explicitly:
//
//   flutter test test/gemini_live_probe.dart
//
// PASS  => the session/backend works; the mic *capture* is the isolated culprit.
// FAIL  => the Gemini connection itself is broken (key/model/quota/region).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

import 'live_token_probe_helper.dart';

String _env(String key) {
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

void main() {
  test('Gemini Live backend responds to a text turn', () async {
    final key = _env('GEMINI_API_KEY');
    expect(key, isNotEmpty, reason: 'GEMINI_API_KEY missing from .env');

    const model = 'gemini-3.1-flash-live-preview';
    final sessionToken = await requestLiveProbeToken(apiKey: key, model: model);
    // ignore: avoid_print
    print('Connecting to Gemini Live (model=$model)…');

    final client = GeminiLiveClient(
      sessionToken: sessionToken,
      model: model,
      systemInstruction:
          'You are a concise journaling assistant. Reply in one short sentence.',
      voice: 'Aoede',
      tools: const [],
    );

    var audioChunks = 0;
    final agent = StringBuffer();
    final done = Completer<String>();

    client
      ..onSetupComplete = () {
        // ignore: avoid_print
        print('setupComplete — sending text turn');
        client.sendText(
            'I had coffee with Maya about the Atlas launch timeline.');
      }
      ..onAgentTranscript = (t, f) {
        agent.write(t);
      }
      ..onAudio = (_) {
        audioChunks++;
      }
      ..onTurnComplete = () {
        if (!done.isCompleted) done.complete('turnComplete');
      }
      ..onError = (e) {
        if (!done.isCompleted) done.completeError(e);
      };

    String result;
    try {
      await client.connect();
      final why = await done.future.timeout(const Duration(seconds: 30));
      result = 'PASS ($why) — agentTranscript="${agent.toString().trim()}" '
          'audioChunks=$audioChunks';
    } on TimeoutException {
      result = 'TIMEOUT — connected but no turn in 30s '
          '(audioChunks=$audioChunks, agent="${agent.toString().trim()}")';
    } catch (e) {
      result = 'FAIL — $e';
    } finally {
      await client.close();
    }

    // ignore: avoid_print
    print('RESULT: $result');
    expect(result, startsWith('PASS'),
        reason: 'backend did not respond to text: $result');
  }, timeout: const Timeout(Duration(seconds: 60)));
}

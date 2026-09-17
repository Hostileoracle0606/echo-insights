// LIVE audio-path probe (excluded from the normal suite — no `_test.dart`
// suffix). Streams REAL synthesized speech through GeminiLiveClient.sendAudio
// exactly as the mic capture would, to isolate whether "no voice activity" is
// the audio wire format or the device mic. Prepare the fixture first:
//
//   say "I had coffee with Maya…" -o /tmp/probe_speech.aiff
//   afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/probe_speech.aiff \
//     /tmp/probe_speech_16k.wav
//   flutter test test/gemini_live_audio_probe.dart
//
// PASS => Gemini transcribed our audio: the send format + transcription config
//         work, so the remaining suspect is the device mic capture.
// FAIL => Gemini ignored the audio: the realtime_input wire format is wrong.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// Extracts raw PCM bytes from a WAV file by locating its 'data' chunk.
Uint8List _wavPcm(String path) {
  final bytes = File(path).readAsBytesSync();
  for (var i = 12; i < bytes.length - 8;) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final size =
        ByteData.sublistView(bytes, i + 4, i + 8).getUint32(0, Endian.little);
    if (id == 'data') return bytes.sublist(i + 8, i + 8 + size);
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}

void main() {
  test('Gemini Live transcribes streamed PCM speech (mic-path simulation)',
      () async {
    final key = _env('GEMINI_API_KEY');
    expect(key, isNotEmpty, reason: 'GEMINI_API_KEY missing from .env');
    final pcm = _wavPcm('/tmp/probe_speech_16k.wav');
    // ignore: avoid_print
    print('speech fixture: ${pcm.length} bytes '
        '(~${(pcm.length / 32000).toStringAsFixed(1)}s @16kHz mono int16)');

    const model = 'gemini-3.1-flash-live-preview';
    final sessionToken = await requestLiveProbeToken(apiKey: key, model: model);
    final client = GeminiLiveClient(
      sessionToken: sessionToken,
      model: model,
      systemInstruction:
          'You are a concise journaling assistant. Reply in one short sentence.',
      voice: 'Aoede',
      tools: const [],
    );

    final userHeard = StringBuffer();
    final agent = StringBuffer();
    var audioChunksIn = 0;
    final turnDone = Completer<void>();
    final ready = Completer<void>();

    client
      ..onSetupComplete = () {
        if (!ready.isCompleted) ready.complete();
      }
      ..onTranscript = (t, f) {
        userHeard.write(t);
      }
      ..onAgentTranscript = (t, f) {
        agent.write(t);
      }
      ..onAudio = (_) {
        audioChunksIn++;
      }
      ..onTurnComplete = () {
        if (!turnDone.isCompleted) turnDone.complete();
      }
      ..onError = (e) {
        if (!turnDone.isCompleted) turnDone.completeError(e);
      };

    String verdict;
    try {
      await client.connect();
      await ready.future.timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print('setupComplete — streaming speech in 100ms chunks…');

      // 100ms of 16kHz mono int16 = 3200 bytes; pace roughly real-time so
      // Gemini's VAD sees a natural utterance, then ~1.6s of silence so
      // end-of-speech fires.
      for (var off = 0; off < pcm.length; off += 3200) {
        final end = (off + 3200 < pcm.length) ? off + 3200 : pcm.length;
        client.sendAudio(Uint8List.sublistView(pcm, off, end));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      final silence = Uint8List(3200);
      for (var i = 0; i < 16; i++) {
        client.sendAudio(silence);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      // ignore: avoid_print
      print('speech + silence sent — waiting for the model turn…');
      await turnDone.future.timeout(const Duration(seconds: 30));
      verdict = 'turnComplete';
    } on TimeoutException {
      verdict = 'TIMEOUT';
    } finally {
      await client.close();
    }

    final heard = userHeard.toString().trim();
    // ignore: avoid_print
    print('RESULT: $verdict\n'
        '  inputTranscription (what Gemini heard): "$heard"\n'
        '  agent reply: "${agent.toString().trim()}"\n'
        '  agent audio chunks: $audioChunksIn');

    expect(heard, isNotEmpty,
        reason: 'Gemini produced no input transcription — it never "heard" '
            'the streamed audio, so the realtime_input wire format is the '
            'prime suspect (verdict=$verdict)');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

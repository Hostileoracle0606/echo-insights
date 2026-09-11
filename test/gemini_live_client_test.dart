import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

void main() {
  GeminiLiveClient makeClient() => GeminiLiveClient(
        sessionToken: 'auth_tokens/temporary token',
        model: 'gemini-live-2.5-flash-preview',
        systemInstruction: 'system',
        voice: 'Aoede',
        tools: const [],
      );

  test('connection URI uses a temporary access token, never an API key', () {
    final uri = makeClient().connectionUri;

    expect(uri.queryParameters['access_token'], 'auth_tokens/temporary token');
    expect(uri.queryParameters.containsKey('key'), isFalse);
    expect(uri.path, endsWith('GenerativeService.BidiGenerateContentConstrained'));
  });

  test('outputTranscription fires onAgentTranscript, not onTranscript', () {
    final client = makeClient();

    final agentCalls = <({String text, bool isFinal})>[];
    final userCalls = <({String text, bool isFinal})>[];
    client.onAgentTranscript =
        (text, isFinal) => agentCalls.add((text: text, isFinal: isFinal));
    client.onTranscript =
        (text, isFinal) => userCalls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'outputTranscription': {'text': 'How did that make you feel?'},
        'turnComplete': true,
      },
    }));

    expect(agentCalls, hasLength(1));
    expect(agentCalls.single.text, 'How did that make you feel?');
    expect(agentCalls.single.isFinal, isTrue);
    // The agent transcription must not leak into the user channel.
    expect(userCalls, isEmpty);
  });

  test('inputTranscription fires onTranscript (user), not onAgentTranscript',
      () {
    final client = makeClient();

    final agentCalls = <({String text, bool isFinal})>[];
    final userCalls = <({String text, bool isFinal})>[];
    client.onAgentTranscript =
        (text, isFinal) => agentCalls.add((text: text, isFinal: isFinal));
    client.onTranscript =
        (text, isFinal) => userCalls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'I had a rough day.'},
        'turnComplete': false,
      },
    }));

    expect(userCalls, hasLength(1));
    expect(userCalls.single.text, 'I had a rough day.');
    expect(userCalls.single.isFinal, isFalse);
    // The user transcription must not leak into the agent channel.
    expect(agentCalls, isEmpty);
  });

  test('an interruption is surfaced, and before turn completion', () {
    final client = makeClient();
    final order = <String>[];
    client.onInterrupted = () => order.add('interrupted');
    client.onTurnComplete = () => order.add('turnComplete');

    client.handleServerMessage(jsonEncode({
      'serverContent': {'interrupted': true, 'turnComplete': true},
    }));

    // Documented Gemini order: an interrupted response goes through
    // `interrupted` to `turnComplete` and never emits generationComplete.
    expect(order, ['interrupted', 'turnComplete']);
  });

  test('a transcription marked finished is final even without turnComplete', () {
    final client = makeClient();
    final calls = <({String text, bool isFinal})>[];
    client.onTranscript = (text, isFinal) => calls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'I work at '},
      },
    }));
    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'Acme.', 'finished': true},
      },
    }));

    expect(calls.map((c) => c.isFinal), [false, true]);
  });
}

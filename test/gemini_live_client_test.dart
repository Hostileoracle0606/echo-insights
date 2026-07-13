import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

void main() {
  GeminiLiveClient makeClient() => GeminiLiveClient(
        apiKey: 'test-key',
        model: 'gemini-live-2.5-flash-preview',
        systemInstruction: 'system',
        voice: 'Aoede',
        tools: const [],
      );

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
}

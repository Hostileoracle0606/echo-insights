import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/services/extract_graph_service.dart';

void main() {
  const notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

  test('sends authenticated extraction context to the Notebook Runtime',
      () async {
    late http.Request captured;
    final service = ExtractGraphService(
      baseUrl: 'https://runtime.example.com/',
      accessTokenProvider: () async => 'signed-user-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'patch': {
              'entities': [
                {'name': 'Maya', 'type': 'person'},
                {'name': 'Lumen', 'type': 'other'},
              ],
              'relations': <dynamic>[],
              'supersedes': <dynamic>[],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final patch = await service.extract(
      notebookId: notebookId,
      turnId: 'turn-123',
      extractorVersion: 'gemini/extract_graph/v2',
      text: 'I met Maya for coffee.',
      state: JournalState.empty(),
      mode: 'granular',
      maxRetries: 0,
    );

    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://runtime.example.com/v1/notebooks/$notebookId/extractions',
    );
    expect(captured.headers['authorization'], 'Bearer signed-user-token');
    expect(captured.headers, isNot(contains('x-goog-api-key')));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['turnId'], 'turn-123');
    expect(body['extractorVersion'], 'gemini/extract_graph/v2');
    expect(body['text'], 'I met Maya for coffee.');
    expect(body['mode'], 'granular');
    expect(body['context'], isA<Map<String, dynamic>>());
    expect(patch.entities.map((entity) => entity.name), ['Maya']);
  });

  test('does not call the runtime without a signed-in session', () async {
    var called = false;
    final service = ExtractGraphService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => null,
      client: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      service.extract(
        notebookId: notebookId,
        turnId: 'turn-123',
        extractorVersion: 'gemini/extract_graph/v2',
        text: 'I met Maya for coffee.',
        state: JournalState.empty(),
        mode: 'granular',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'A signed-in session is required',
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('rejects malformed runtime responses', () async {
    final service = ExtractGraphService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => 'signed-user-token',
      client: MockClient((request) async => http.Response('{}', 200)),
    );

    await expectLater(
      service.extract(
        notebookId: notebookId,
        turnId: 'turn-123',
        extractorVersion: 'gemini/extract_graph/v2',
        text: 'I met Maya for coffee.',
        state: JournalState.empty(),
        mode: 'granular',
        maxRetries: 0,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

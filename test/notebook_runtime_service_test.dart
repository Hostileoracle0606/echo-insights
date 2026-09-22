import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/services/notebook_runtime_service.dart';

void main() {
  test('requests a temporary live credential with the Supabase access token',
      () async {
    late http.Request captured;
    final service = NotebookRuntimeService(
      baseUrl: 'https://runtime.example.com/',
      accessTokenProvider: () async => 'signed-user-token',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'status': 'ready',
            'sessionToken': 'auth_tokens/temporary-token',
            'expiresAt': '2026-09-07T12:30:00.000Z',
            'model': 'gemini-3.1-flash-live-preview',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final outcome = await service.startLiveSession(
      '8e03b8f4-4f20-4df3-8398-d854adc32b14',
    );

    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://runtime.example.com/v1/notebooks/'
      '8e03b8f4-4f20-4df3-8398-d854adc32b14/live-sessions',
    );
    expect(captured.headers['authorization'], 'Bearer signed-user-token');
    expect(outcome, isA<LiveSessionReady>());
    final ready = outcome as LiveSessionReady;
    expect(ready.sessionToken, 'auth_tokens/temporary-token');
    expect(ready.expiresAt, DateTime.parse('2026-09-07T12:30:00.000Z'));
    expect(ready.model, 'gemini-3.1-flash-live-preview');
  });

  test('does not call the runtime without a signed-in session', () async {
    var called = false;
    final service = NotebookRuntimeService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => null,
      client: MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      service.startLiveSession('8e03b8f4-4f20-4df3-8398-d854adc32b14'),
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

  test('returns an expected broker rejection as a domain outcome', () async {
    final service = NotebookRuntimeService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => 'signed-user-token',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'status': 'rejected', 'code': 'rateLimited'}),
          429,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final outcome = await service.startLiveSession(
      '8e03b8f4-4f20-4df3-8398-d854adc32b14',
    );

    expect(outcome, isA<LiveSessionRejected>());
    expect((outcome as LiveSessionRejected).code, 'rateLimited');
  });

  test('rejects expired authentication and malformed broker responses',
      () async {
    final expired = NotebookRuntimeService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => 'expired-token',
      client: MockClient((request) async => http.Response('', 401)),
    );
    await expectLater(
      expired.startLiveSession('8e03b8f4-4f20-4df3-8398-d854adc32b14'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'The signed-in session is no longer valid',
        ),
      ),
    );

    final malformed = NotebookRuntimeService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => 'signed-user-token',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'status': 'ready'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      malformed.startLiveSession('8e03b8f4-4f20-4df3-8398-d854adc32b14'),
      throwsA(isA<FormatException>()),
    );
  });
}

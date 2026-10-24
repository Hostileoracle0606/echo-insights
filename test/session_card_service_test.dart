import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/models/conversation_mode.dart';
import 'package:lumen/services/session_card_service.dart';

void main() {
  const notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';
  final cardJson = jsonDecode(
    File('contracts/fixtures/session-card-v1.just_talk.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  http.Response json(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  SessionCardService service(
    MockClientHandler handler, {
    SessionCardReader? readCard,
  }) =>
      SessionCardService(
        baseUrl: 'https://runtime.example.com/',
        accessTokenProvider: () async => 'signed-user-token',
        client: MockClient(handler),
        readCard: readCard,
        retryBaseDelay: Duration.zero,
      );

  test('close posts to the runtime as the user and returns the card', () async {
    late http.Request captured;
    final card = await service((request) async {
      captured = request;
      return json(200, {'status': 'ready', 'card': cardJson});
    }).close(notebookId);

    expect(captured.method, 'POST');
    expect(
      captured.url.toString(),
      'https://runtime.example.com/v1/notebooks/$notebookId/close',
    );
    expect(captured.headers['authorization'], 'Bearer signed-user-token');
    expect(card!.conversationMode, ConversationMode.justTalk);
    expect(card.title, cardJson['title']);
    expect(card.notes, hasLength(3));
  });

  test('close shares one request per notebook while it is in flight', () async {
    var calls = 0;
    final respond = Completer<http.Response>();
    final cards = service((_) {
      calls += 1;
      return respond.future;
    });

    // Leaving fires one in the background; the card screen asks again.
    final fromLeaving = cards.close(notebookId);
    final fromScreen = cards.close(notebookId);
    expect(identical(fromLeaving, fromScreen), isTrue);

    respond.complete(json(200, {'status': 'ready', 'card': cardJson}));
    expect((await fromScreen)!.title, cardJson['title']);
    await fromLeaving;
    expect(calls, 1);

    // Once it settles, the next close is a new request.
    final fresh = Completer<http.Response>();
    final again = service((_) {
      calls += 1;
      return fresh.future;
    });
    expect(identical(again.close(notebookId), again.close('other')), isFalse);
  });

  test('a finished close does not hold the next one', () async {
    var calls = 0;
    final cards = service((_) async {
      calls += 1;
      return calls == 1
          ? json(409, {'status': 'rejected', 'code': 'stale'})
          : json(200, {'status': 'ready', 'card': cardJson});
    });

    await expectLater(
        cards.close(notebookId), throwsA(isA<SessionCardException>()));
    // Try again after a failure sends a new request.
    expect(await cards.close(notebookId), isNotNull);
    expect(calls, 2);
  });

  test('close returns null when the mode has no card yet (501)', () async {
    final card = await service(
      (_) async => json(501, {'status': 'rejected', 'code': 'notImplemented'}),
    ).close(notebookId);
    expect(card, isNull);
  });

  test('close returns null when there was nothing to summarize (422)',
      () async {
    final card = await service(
      (_) async =>
          json(422, {'status': 'rejected', 'code': 'nothingToSummarize'}),
    ).close(notebookId);
    expect(card, isNull);
  });

  test('close reports a stale save (409) without retrying', () async {
    var calls = 0;
    final closing = service((_) async {
      calls += 1;
      return json(409, {'status': 'rejected', 'code': 'stale'});
    }).close(notebookId);

    await expectLater(
      closing,
      throwsA(isA<SessionCardException>()
          .having((error) => error.statusCode, 'statusCode', 409)
          .having((error) => error.code, 'code', 'stale')),
    );
    expect(calls, 1, reason: 'the runtime already retried once');
  });

  test('close retries 5xx and 429, then gives up', () async {
    var calls = 0;
    final closing = service((_) async {
      calls += 1;
      return json(503, {'status': 'rejected', 'code': 'providerUnavailable'});
    }).close(notebookId, maxRetries: 2);

    await expectLater(
      closing,
      throwsA(isA<SessionCardException>()
          .having((error) => error.code, 'code', 'providerUnavailable')),
    );
    expect(calls, 3);
  });

  test('close succeeds after a transient 429', () async {
    var calls = 0;
    final card = await service((_) async {
      calls += 1;
      return calls == 1
          ? json(429, {'status': 'rejected', 'code': 'rateLimited'})
          : json(200, {'status': 'ready', 'card': cardJson});
    }).close(notebookId);
    expect(card, isNotNull);
    expect(calls, 2);
  });

  test('close treats 401 and 403 as a session problem, not a retry', () async {
    for (final status in [401, 403]) {
      var calls = 0;
      final closing = service((_) async {
        calls += 1;
        return json(status, {'status': 'rejected', 'code': 'unauthorized'});
      }).close(notebookId);
      await expectLater(closing, throwsStateError);
      expect(calls, 1);
    }
  });

  test('close needs a configured runtime and a signed-in user', () async {
    final unconfigured = SessionCardService(
      baseUrl: '',
      accessTokenProvider: () async => 'token',
      client: MockClient((_) async => fail('no request expected')),
    );
    await expectLater(unconfigured.close(notebookId), throwsStateError);

    final signedOut = SessionCardService(
      baseUrl: 'https://runtime.example.com',
      accessTokenProvider: () async => null,
      client: MockClient((_) async => fail('no request expected')),
    );
    await expectLater(signedOut.close(notebookId), throwsStateError);
  });

  test('a malformed 200 is a format error', () async {
    final closing = service(
      (_) async => json(200, {
        'status': 'ready',
        'card': {'version': 1}
      }),
    ).close(notebookId);
    await expectLater(closing, throwsFormatException);
  });

  test('load reads the stored card, or null when none exists', () async {
    final requested = <String>[];
    final cards = service(
      (_) async => fail('load never calls the runtime'),
      readCard: (id) async {
        requested.add(id);
        return id == notebookId ? cardJson : null;
      },
    );

    final stored = await cards.load(notebookId);
    expect(stored!.notebookId, notebookId);
    expect(await cards.load('another-notebook'), isNull);
    expect(requested, [notebookId, 'another-notebook']);
  });
}

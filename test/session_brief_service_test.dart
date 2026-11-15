import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/services/session_brief_service.dart';

import 'support/pseudonyms.dart';

void main() {
  test('fromJson decodes the audio and parses the timestamps', () {
    final bytes = Uint8List.fromList([0, 1, 2, 250, 255]);
    final brief = SessionBrief.fromJson({
      'focus': ['a', 'b'],
      'openingThread': 'thread',
      'openingLine': 'Hi there',
      'sourceNotebookId': null,
      'createdAt': '2026-10-28T23:57:01.123456+00:00',
      'playedAt': '2026-10-29T08:00:00+00:00',
      'sampleRate': 24000,
      'audioBase64': base64Encode(bytes),
    });
    expect(brief.pcm, bytes);
    expect(brief.focus, ['a', 'b']);
    expect(brief.sampleRate, 24000);
    expect(
        brief.createdAt
            .isAtSameMomentAs(DateTime.utc(2026, 10, 28, 23, 57, 1, 123, 456)),
        isTrue);
    expect(brief.playedAt, isNotNull);
  });

  test('requestBrief POSTs v2 to the brief route with a bearer token',
      () async {
    final seen = <http.Request>[];
    final service = SessionBriefService(
      baseUrl: 'https://runtime.test/',
      accessTokenProvider: () async => 'tok',
      client: MockClient((request) async {
        seen.add(request);
        return http.Response('{"status":"unchanged"}', 200);
      }),
      rpc: (_, [__]) async => null,
      inputs: FixedInputs(),
      pseudonyms: testPseudonyms(),
    );
    await service.requestBrief('nb-1');
    expect(seen, hasLength(1));
    expect(seen.single.method, 'POST');
    expect(seen.single.url.toString(),
        'https://runtime.test/v1/notebooks/nb-1/brief');
    expect(seen.single.headers['authorization'], 'Bearer tok');
    expect((jsonDecode(seen.single.body) as Map)['version'], 2);
  });

  test('requestBrief throws on a non-200', () async {
    final service = SessionBriefService(
      baseUrl: 'https://runtime.test',
      accessTokenProvider: () async => 'tok',
      client: MockClient((_) async => http.Response('{}', 501)),
      rpc: (_, [__]) async => null,
      inputs: FixedInputs(),
      pseudonyms: testPseudonyms(),
    );
    expect(service.requestBrief('nb-1'), throwsA(isA<Exception>()));
  });

  test('load reads get_session_brief', () async {
    String? called;
    final service = SessionBriefService(
      baseUrl: 'https://runtime.test',
      accessTokenProvider: () async => 'tok',
      inputs: FixedInputs(),
      pseudonyms: testPseudonyms(),
      rpc: (fn, [params]) async {
        called = fn;
        return {'returning': true, 'brief': null};
      },
    );
    final state = await service.load();
    expect(called, 'get_session_brief');
    expect(state.returning, isTrue);
    expect(state.brief, isNull);
  });

  test('markPlayed sends a string that round-trips microseconds', () async {
    Map<String, dynamic>? sentParams;
    String? fn;
    final service = SessionBriefService(
      baseUrl: 'https://runtime.test',
      accessTokenProvider: () async => 'tok',
      inputs: FixedInputs(),
      pseudonyms: testPseudonyms(),
      rpc: (name, [params]) async {
        fn = name;
        sentParams = params;
        return null;
      },
    );
    final parsed = DateTime.parse('2026-10-28T23:57:01.123456+00:00');
    await service.markPlayed(parsed);
    expect(fn, 'mark_session_brief_played');
    final sent = sentParams!['p_created_at'] as String;
    expect(DateTime.parse(sent).isAtSameMomentAs(parsed), isTrue);
    expect(DateTime.parse(sent).microsecondsSinceEpoch,
        parsed.microsecondsSinceEpoch);
  });
}

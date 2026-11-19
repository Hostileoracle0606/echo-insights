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

  group('LM-102: ask before spending a model call', () {
    SessionBriefService build(
      Future<http.Response> Function(http.Request) handler,
      BriefRpc rpc,
    ) =>
        SessionBriefService(
          baseUrl: 'https://runtime.test',
          accessTokenProvider: () async => 'tok',
          client: MockClient(handler),
          rpc: rpc,
          inputs: FixedInputs(),
          pseudonyms: testPseudonyms(),
        );

    test('briefStatus reads get_brief_status for the notebook and revision',
        () async {
      String? fn;
      Map<String, dynamic>? sent;
      final status = await build(
        (_) async => fail('no runtime call'),
        (name, [params]) async {
          fn = name;
          sent = params;
          return {
            'status': 'present',
            'briefRevision': 7,
            'currentRevision': 7,
          };
        },
      ).briefStatus('nb-1', 7);
      expect(fn, 'get_brief_status');
      expect(sent, {'p_notebook_id': 'nb-1', 'p_revision': 7});
      expect(status.isPresent, isTrue);
      expect(status.briefRevision, 7);
    });

    test('a brief already stored at the current revision: nothing is sent',
        () async {
      var posts = 0;
      await build(
        (_) async {
          posts += 1;
          return http.Response('{"status":"unchanged"}', 200);
        },
        (fn, [_]) async =>
            {'status': 'present', 'briefRevision': 7, 'currentRevision': 7},
      ).requestBrief('nb-1');
      expect(posts, 0);
    });

    test('asking twice for the same revision makes one model call', () async {
      var posts = 0;
      var stored = false;
      final service = build(
        (_) async {
          posts += 1;
          stored = true;
          return http.Response('{"status":"unchanged"}', 200);
        },
        (fn, [_]) async => {
          'status': stored ? 'present' : 'absent',
          'currentRevision': 7,
        },
      );
      await service.requestBrief('nb-1');
      await service.requestBrief('nb-1');
      expect(posts, 1);
    });

    test('keyReused on the save is already done, not an error', () async {
      final calls = <String>[];
      await build(
        (request) async {
          final body = jsonDecode(request.body) as Map;
          if (body['speak'] != null) {
            return http.Response(
              jsonEncode({
                'status': 'ready',
                'audioBase64': 'AQID',
                'sampleRate': 24000,
                'openingLine': 'Hi',
                'sourceRevision': 7,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'status': 'ready',
              'brief': {
                'focus': <String>[],
                'openingThread': '',
                'openingLine': 'Hi',
              },
              'speakToken': 'tkn',
              'sourceRevision': 7,
            }),
            200,
          );
        },
        (fn, [_]) async {
          calls.add(fn);
          return fn == 'get_brief_status'
              ? {'status': 'absent', 'currentRevision': 7}
              : {'status': 'rejected', 'code': 'keyReused'};
        },
      ).requestBrief('nb-1');
      expect(calls, ['get_brief_status', 'save_session_brief']);
    });
  });
}

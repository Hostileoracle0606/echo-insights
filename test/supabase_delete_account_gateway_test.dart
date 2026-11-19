// The real `delete-account` gateway against a stubbed HTTP layer: which
// failures prove the session is gone (the deletion counts as done and the
// phone is wiped) and which are only transient (the marker is kept and the
// resend waits for the next launch).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/services/account_deletion_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'https://lumen.test';

String _jwt(Map<String, Object> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.sig';
}

Map<String, Object> _session() {
  final exp =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
          1000;
  return {
    'access_token': _jwt({'sub': 'user-1', 'exp': exp}),
    'expires_in': 3600,
    'refresh_token': 'refresh-1',
    'token_type': 'bearer',
    'user': {
      'id': 'user-1',
      'aud': 'authenticated',
      'app_metadata': <String, Object>{},
      'user_metadata': <String, Object>{},
      'created_at': '2026-11-01T00:00:00Z',
    },
  };
}

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {
        'content-type': 'application/json',
        'x-supabase-api-version': '2024-01-01',
      },
    );

void main() {
  late SupabaseClient client;
  late Future<http.Response> Function(http.Request) token;
  late Future<http.Response> Function(http.Request) function;
  late List<Map<String, dynamic>> functionBodies;

  setUp(() async {
    functionBodies = [];
    token = (_) async => _json(200, _session());
    function = (_) async => _json(
        200, {'queued': true, 'already_queued': false, 'apple_revoked': null});
    client = SupabaseClient(
      _url,
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/auth/v1/token')) return token(request);
        if (path.endsWith('/functions/v1/delete-account')) {
          functionBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return function(request);
        }
        return http.Response('', 404);
      }),
    );
    await client.auth.recoverSession(jsonEncode(_session()));
  });

  tearDown(() => client.dispose());

  SupabaseDeleteAccountGateway gateway() =>
      SupabaseDeleteAccountGateway(client);

  group('refresh', () {
    test('no session at all -> gone', () async {
      await client.auth.signOut(scope: SignOutScope.local);
      await expectLater(
          gateway().refreshSession(), throwsA(isA<DeletionSessionGone>()));
    });

    for (final code in [
      'refresh_token_not_found',
      'session_not_found',
      'user_not_found',
    ]) {
      test('400 $code -> gone', () async {
        token = (_) async =>
            _json(400, {'code': code, 'msg': 'server text, never shown'});
        await expectLater(
            gateway().refreshSession(), throwsA(isA<DeletionSessionGone>()));
      });
    }

    final transient = <String, Future<http.Response> Function(http.Request)>{
      '429 rate limit': (_) async =>
          _json(429, {'code': 'over_request_rate_limit', 'msg': 'slow down'}),
      'empty-body 403': (_) async => http.Response('', 403),
      '400 with another code': (_) async =>
          _json(400, {'code': 'validation_failed', 'msg': 'x'}),
      '503': (_) async => http.Response('unavailable', 503),
      'socket error': (_) async => throw const SocketException('offline'),
    };
    transient.forEach((name, reply) {
      test('$name -> transient, not gone', () async {
        token = reply;
        Object? thrown;
        try {
          await gateway().refreshSession();
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isNotNull);
        expect(thrown, isNot(isA<DeletionSessionGone>()));
      }, timeout: const Timeout(Duration(seconds: 40)));
    });
  });

  group('call', () {
    test('200 queued -> queued, and the body carries request_id and the code',
        () async {
      final g = gateway();
      await g.refreshSession();
      final reply = await g.call(
          requestId: 'req-1', appleAuthorizationCode: 'apple-code');

      expect(reply.queued, isTrue);
      expect(reply.alreadyQueued, isFalse);
      expect(reply.appleRevoked, isNull);
      expect(functionBodies.single,
          {'request_id': 'req-1', 'apple_authorization_code': 'apple-code'});
    });

    test('200 already_queued, no Apple code -> only request_id is sent',
        () async {
      function = (_) async => _json(
          200, {'queued': true, 'already_queued': true, 'apple_revoked': null});
      final g = gateway();
      await g.refreshSession();
      final reply = await g.call(requestId: 'req-1');

      expect(reply.queued, isTrue);
      expect(reply.alreadyQueued, isTrue);
      expect(functionBodies.single, {'request_id': 'req-1'});
    });

    for (final status in [401, 500]) {
      test('function $status -> transient, not gone', () async {
        function = (_) async => _json(status, {'error': 'server text'});
        final g = gateway();
        await g.refreshSession();
        Object? thrown;
        try {
          await g.call(requestId: 'req-1');
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isNotNull);
        expect(thrown, isNot(isA<DeletionSessionGone>()));
      });
    }
  });
}

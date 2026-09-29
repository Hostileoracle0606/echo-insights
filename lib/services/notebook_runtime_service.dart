import 'dart:convert';

import 'package:http/http.dart' as http;

sealed class LiveSessionOutcome {
  const LiveSessionOutcome();
}

class LiveSessionReady extends LiveSessionOutcome {
  final String sessionToken;
  final DateTime expiresAt;
  final String model;

  /// The last moment a new connection may start with [sessionToken]. Null
  /// from runtimes deployed before the field existed.
  final DateTime? newSessionExpiresAt;

  const LiveSessionReady({
    required this.sessionToken,
    required this.expiresAt,
    required this.model,
    this.newSessionExpiresAt,
  });
}

class LiveSessionRejected extends LiveSessionOutcome {
  final String code;

  const LiveSessionRejected(this.code);
}

class NotebookRuntimeService {
  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final http.Client _client;

  NotebookRuntimeService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client();

  /// The notebook's route: checks the notebook is the user's, 60 s window.
  Future<LiveSessionOutcome> startLiveSession(String notebookId) => _post(
        '/v1/notebooks/${Uri.encodeComponent(notebookId)}/live-sessions',
      );

  /// The user-scoped route: no notebook needed, a longer start window. A
  /// runtime deployed without it answers [LiveSessionRejected] with
  /// [routeUnavailableCode].
  Future<LiveSessionOutcome> startUserLiveSession() =>
      _post('/v1/live-sessions');

  /// API Gateway's own 404 for a route that isn't deployed (no `status`).
  static const routeUnavailableCode = 'routeUnavailable';

  bool get isConfigured => _baseUrl.isNotEmpty;

  Future<LiveSessionOutcome> _post(String path) async {
    if (_baseUrl.isEmpty) {
      throw StateError('The secure live-session route is not configured');
    }
    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }

    final response = await _client.post(
      Uri.parse('$_baseUrl$path'),
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer $accessToken',
      },
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('The signed-in session is no longer valid');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode == 404) {
        return const LiveSessionRejected(routeUnavailableCode);
      }
      rethrow;
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Notebook Runtime response');
    }
    if (response.statusCode == 404 && decoded['status'] == null) {
      return const LiveSessionRejected(routeUnavailableCode);
    }

    if (decoded['status'] == 'ready' &&
        decoded['sessionToken'] is String &&
        decoded['expiresAt'] is String &&
        decoded['model'] is String) {
      return LiveSessionReady(
        sessionToken: decoded['sessionToken'] as String,
        expiresAt: DateTime.parse(decoded['expiresAt'] as String),
        model: decoded['model'] as String,
        newSessionExpiresAt: decoded['newSessionExpiresAt'] is String
            ? DateTime.tryParse(decoded['newSessionExpiresAt'] as String)
            : null,
      );
    }

    final code = decoded['code'];
    if (decoded['status'] == 'rejected' &&
        (code == 'notFound' ||
            code == 'rateLimited' ||
            code == 'providerUnavailable')) {
      return LiveSessionRejected(code as String);
    }

    throw const FormatException('Invalid Notebook Runtime response');
  }
}

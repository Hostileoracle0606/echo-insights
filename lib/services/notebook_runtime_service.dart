import 'dart:convert';

import 'package:http/http.dart' as http;

sealed class LiveSessionOutcome {
  const LiveSessionOutcome();
}

class LiveSessionReady extends LiveSessionOutcome {
  final String sessionToken;
  final DateTime expiresAt;
  final String model;

  const LiveSessionReady({
    required this.sessionToken,
    required this.expiresAt,
    required this.model,
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

  Future<LiveSessionOutcome> startLiveSession(String notebookId) async {
    if (_baseUrl.isEmpty) {
      throw StateError('The secure live-session route is not configured');
    }
    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }

    final response = await _client.post(
      Uri.parse(
        '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/live-sessions',
      ),
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer $accessToken',
      },
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw StateError('The signed-in session is no longer valid');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Notebook Runtime response');
    }

    if (decoded['status'] == 'ready' &&
        decoded['sessionToken'] is String &&
        decoded['expiresAt'] is String &&
        decoded['model'] is String) {
      return LiveSessionReady(
        sessionToken: decoded['sessionToken'] as String,
        expiresAt: DateTime.parse(decoded['expiresAt'] as String),
        model: decoded['model'] as String,
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

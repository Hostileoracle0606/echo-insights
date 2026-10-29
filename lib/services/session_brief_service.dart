import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/session_brief.dart';

/// Calls a Supabase RPC and returns its JSON result.
typedef BriefRpc = Future<Object?> Function(
  String fn, [
  Map<String, dynamic>? params,
]);

class SessionBriefException implements Exception {
  const SessionBriefException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'SessionBriefException: $message'
      : 'SessionBriefException ($statusCode): $message';
}

/// The session brief (LM-40): asks the notebook runtime to write one
/// (`POST /v1/notebooks/{id}/brief`), reads the stored one, and marks it
/// played.
class SessionBriefService {
  SessionBriefService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    required BriefRpc rpc,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _rpc = rpc,
        _client = client ?? http.Client();

  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final BriefRpc _rpc;
  final http.Client _client;

  /// Asks the runtime to (re)write the brief for [notebookId]. Errors are
  /// thrown; the caller logs them.
  Future<void> requestBrief(String notebookId) async {
    if (_baseUrl.isEmpty) {
      throw StateError('The secure notebook runtime is not configured');
    }
    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }
    final response = await _client.post(
      Uri.parse(
        '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/brief',
      ),
      headers: {
        'accept': 'application/json',
        'authorization': 'Bearer $accessToken',
        'content-type': 'application/json',
      },
      body: '{}',
    );
    if (response.statusCode != 200) {
      throw SessionBriefException(
        'The notebook runtime could not write the session brief',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map ||
        (decoded['status'] != 'ready' && decoded['status'] != 'unchanged')) {
      throw const FormatException('Invalid session-brief response');
    }
  }

  /// The sign-in lookup (`get_session_brief`).
  Future<SessionOpeningState> load() async {
    final result = await _rpc('get_session_brief');
    if (result is! Map) {
      throw const FormatException('Invalid get_session_brief response');
    }
    return SessionOpeningState.fromJson(result);
  }

  /// Marks the brief created at [createdAt] as played. The server matches
  /// the instant exactly, so it goes out in UTC with microseconds intact.
  Future<void> markPlayed(DateTime createdAt) async {
    await _rpc('mark_session_brief_played', {
      'p_created_at': createdAt.toUtc().toIso8601String(),
    });
  }
}

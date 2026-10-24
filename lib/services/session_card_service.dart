import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/session_card.dart';

/// Reads the stored card JSON for a notebook (`session_cards.card`), or null.
typedef SessionCardReader = Future<Object?> Function(String notebookId);

class SessionCardException implements Exception {
  final String message;
  final int? statusCode;

  /// The runtime's rejection code, e.g. `stale` or `providerUnavailable`.
  final String? code;

  const SessionCardException(this.message, {this.statusCode, this.code});

  @override
  String toString() => statusCode == null
      ? 'SessionCardException: $message'
      : 'SessionCardException ($statusCode${code == null ? '' : ' $code'}): '
          '$message';
}

/// The closing card for a conversation (LM-15): asks the notebook runtime to
/// write it (`POST /v1/notebooks/{id}/close`) and reads stored ones.
///
/// The runtime returns the stored card without a model call when the
/// notebook hasn't changed since it was written, so [close] is cheap to
/// repeat.
class SessionCardService {
  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final http.Client _client;
  final SessionCardReader? _readCard;
  final Duration _retryBaseDelay;

  SessionCardService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    http.Client? client,
    SessionCardReader? readCard,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client(),
        _readCard = readCard,
        _retryBaseDelay = retryBaseDelay;

  /// Writes (or returns the current) card for [notebookId]. Null when the
  /// notebook's mode has no card yet (501) or the user said nothing to
  /// summarize (422).
  Future<SessionCard?> close(String notebookId, {int maxRetries = 2}) async {
    if (_baseUrl.isEmpty) {
      throw StateError('The secure notebook runtime is not configured');
    }
    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }
    final url = Uri.parse(
      '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/close',
    );

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      final http.Response response;
      try {
        response = await _client.post(
          url,
          headers: {
            'accept': 'application/json',
            'authorization': 'Bearer $accessToken',
            'content-type': 'application/json',
          },
          body: '{}',
        );
      } on http.ClientException {
        if (attempt == maxRetries) rethrow;
        await Future<void>.delayed(_retryBaseDelay * (1 << attempt));
        continue;
      }

      final status = response.statusCode;
      if (status == 401 || status == 403) {
        throw StateError('The signed-in session is no longer valid');
      }
      if (status == 501 || status == 422) return null;
      if ((status == 429 || status >= 500) && attempt < maxRetries) {
        await Future<void>.delayed(_retryBaseDelay * (1 << attempt));
        continue;
      }
      if (status != 200) {
        throw SessionCardException(
          'The notebook runtime could not write the session card',
          statusCode: status,
          code: _code(response.body),
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['status'] != 'ready') {
        throw const FormatException('Invalid session-card response');
      }
      return SessionCard.fromJson(decoded['card']);
    }
    // Unreachable: the last attempt either returns or throws.
    throw const SessionCardException('The session card was not written');
  }

  /// The stored card for [notebookId], or null when none was written yet.
  Future<SessionCard?> load(String notebookId) async {
    final readCard = _readCard;
    if (readCard == null) {
      throw StateError('Stored session cards are not readable here');
    }
    final card = await readCard(notebookId);
    return card == null ? null : SessionCard.fromJson(card);
  }

  static String? _code(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['code'] is String
          ? decoded['code'] as String
          : null;
    } on FormatException {
      return null;
    }
  }
}

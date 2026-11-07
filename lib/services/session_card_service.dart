import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/session_card.dart';
import 'model_inputs.dart';
import 'pseudonym_service.dart';

/// Reads the stored card JSON for a notebook (`session_cards.card`), or null.
typedef SessionCardReader = Future<Object?> Function(String notebookId);

/// Calls a Supabase RPC with the user's token and returns its JSON result.
typedef CardRpc = Future<Object?> Function(
  String fn, [
  Map<String, dynamic>? params,
]);

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
///
/// LM-56 (request v2, contracts/close-session-v2.md): the transcript is read
/// here, its names swapped on the device (each turn once, from the swap
/// cache), and sent with the request. The card comes back unsaved with
/// stand-ins in its text; they are swapped back here and the card is saved
/// through `save_session_card`, where the revision, draft, cap and
/// forgotten-name rules run as they do for the runtime.
class SessionCardService {
  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final http.Client _client;
  final SessionCardReader? _readCard;
  final Duration _retryBaseDelay;
  final ModelInputSource _inputs;
  final PseudonymService _pseudonyms;
  final CardRpc _rpc;

  /// Calls still running, by notebook: leaving a notebook fires one in the
  /// background and the closing card screen (LM-16) asks again on arrival,
  /// so both share one request instead of writing the card twice.
  final _inFlight = <String, Future<SessionCard?>>{};

  SessionCardService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    http.Client? client,
    required ModelInputSource inputs,
    required PseudonymService pseudonyms,
    required CardRpc rpc,
    SessionCardReader? readCard,
    Duration retryBaseDelay = const Duration(milliseconds: 500),
  })  : _inputs = inputs,
        _pseudonyms = pseudonyms,
        _rpc = rpc,
        _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _client = client ?? http.Client(),
        _readCard = readCard,
        _retryBaseDelay = retryBaseDelay;

  /// Writes (or returns the current) card for [notebookId]. Null when the
  /// notebook's mode has no card yet (501) or the user said nothing to
  /// summarize (422). While a call for [notebookId] is running, returns that
  /// same future.
  Future<SessionCard?> close(String notebookId, {int maxRetries = 2}) {
    final running = _inFlight[notebookId];
    if (running != null) return running;
    final closing = _close(notebookId, maxRetries);
    _inFlight[notebookId] = closing;
    // whenComplete would hand the error to a second, unawaited future.
    void settle() {
      if (identical(_inFlight[notebookId], closing)) {
        _inFlight.remove(notebookId);
      }
    }

    closing.then((_) => settle(), onError: (Object _) => settle());
    return closing;
  }

  /// A draft of the card from the conversation so far, written in the
  /// background while it goes on (see CardDrafter). Best-effort: one
  /// attempt, never shared with [close]. Null when there is nothing to
  /// summarize yet or the mode has no card.
  Future<SessionCard?> draft(String notebookId) =>
      _close(notebookId, 0, draft: true);

  Future<SessionCard?> _close(
    String notebookId,
    int maxRetries, {
    bool draft = false,
  }) async {
    // A final card that went stale while it was written (a turn landed in
    // between) is asked for once more, as the runtime did before LM-56.
    for (var pass = 0;; pass++) {
      final outcome = await _closeOnce(notebookId, maxRetries, draft: draft);
      if (outcome is! _Stale) return (outcome as _Done).card;
      if (draft || pass == 1) {
        throw const SessionCardException(
          'The conversation moved on while its card was written',
          statusCode: 409,
          code: 'stale',
        );
      }
    }
  }

  Future<_Outcome> _closeOnce(
    String notebookId,
    int maxRetries, {
    required bool draft,
  }) async {
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

    final input = await _inputs.card(notebookId);
    // Nothing the user said is left (none was said, or auto-forget took the
    // turns): nothing to write from. A card written earlier is kept, as the
    // runtime keeps it.
    if (!input.turns.any(
      (t) => t.speaker == 'user' && t.text.trim().isNotEmpty,
    )) {
      return _Done(_readCard == null ? null : await load(notebookId));
    }
    await _pseudonyms.syncGraph(input.candidates);
    final swapped = await _pseudonyms.swapTurns(
      [for (final t in input.turns) t.text],
      extras: [for (final e in input.candidates) e.name],
    );
    // Nobody signed in: the map can't swap, so nothing is sent.
    if (swapped == null) throw StateError('A signed-in session is required');
    final body = jsonEncode({
      'version': 2,
      if (draft) 'draft': true,
      'turns': [
        for (var i = 0; i < input.turns.length; i++)
          {'speaker': input.turns[i].speaker, 'text': swapped.turns[i]},
      ],
      'entities': [
        for (var i = 0; i < input.candidates.length; i++)
          {
            'key': entityKey(notebookId, input.candidates[i].id),
            'name': swapped.extras[i],
          },
      ],
      'sourceRevision': input.revision,
    });

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
          body: body,
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
      if (status == 501 || status == 422) return const _Done(null);
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
      if (decoded is! Map ||
          decoded['status'] != 'ready' ||
          decoded['card'] is! Map) {
        throw const FormatException('Invalid session-card response');
      }
      final card = (decoded['card'] as Map).cast<String, dynamic>();
      if (decoded['saved'] != false) return _Done(SessionCard.fromJson(card));
      // Through JSON once more: the swap returns loosely typed maps.
      final real =
          jsonDecode(jsonEncode(await _swapBack(card))) as Map<String, dynamic>;
      return _save(notebookId, real, draft: draft);
    }
    // Unreachable: the last attempt either returns or throws.
    throw const SessionCardException('The session card was not written');
  }

  /// Model-written text swapped back to real names. What identifies the card
  /// and the remember list's ids, names and types come from the database
  /// and stay as they are; only the notes in it are the model's.
  Future<Map<String, dynamic>> _swapBack(Map<String, dynamic> card) async {
    const fixed = {
      'version',
      'notebookId',
      'conversationMode',
      'sourceRevision',
      'generatedAt',
      'remember',
    };
    final out = <String, dynamic>{};
    for (final entry in card.entries) {
      out[entry.key] = fixed.contains(entry.key)
          ? entry.value
          : await _pseudonyms.rehydrateJson(entry.value);
    }
    final remember = card['remember'];
    if (remember is List) {
      out['remember'] = [
        for (final item in remember)
          if (item is Map && item['note'] is String)
            {
              ...item.cast<String, dynamic>(),
              'note': await _pseudonyms
                  .rehydrateModelOutput(item['note'] as String),
            }
          else
            item,
      ];
    }
    return out;
  }

  /// Saves the card with the user's token. The function applies every rule
  /// the runtime's save did: a final card must match the notebook's
  /// revision, a draft may not be ahead of it, the caps, and forgotten names
  /// are redacted. Returns the stored card (redacted), or stale.
  Future<_Outcome> _save(
    String notebookId,
    Map<String, dynamic> card, {
    required bool draft,
  }) async {
    final result = await _rpc('save_session_card', {
      'p_notebook_id': notebookId,
      'p_source_revision': card['sourceRevision'],
      'p_card': card,
      'p_title': card['title'],
      'p_summary': card['summary'],
      if (draft) 'p_draft': true,
    });
    if (result is Map && result['status'] == 'saved' && result['card'] is Map) {
      return _Done(SessionCard.fromJson(result['card']));
    }
    if (result is Map && result['status'] == 'stale') return const _Stale();
    if (result is Map && result['code'] == 'notFound') {
      throw const SessionCardException(
        'The notebook was not found',
        statusCode: 404,
        code: 'notFound',
      );
    }
    throw const FormatException('Invalid save_session_card response');
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

sealed class _Outcome {
  const _Outcome();
}

class _Done extends _Outcome {
  const _Done(this.card);
  final SessionCard? card;
}

class _Stale extends _Outcome {
  const _Stale();
}

/// How a v2 close names an entity (contracts/close-session-v2.md): an id is
/// the real name's slug, so it never goes in the body; this salted hash
/// does, and the runtime hashes the notebook's ids the same way.
String entityKey(String notebookId, String entityId) =>
    sha256.convert(utf8.encode('$notebookId:$entityId')).toString();

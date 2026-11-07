import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/noise_filter.dart';
import '../logic/slugify.dart';
import '../logic/turn_state.dart' show Speaker;
import '../models/follow_up.dart';
import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import 'extraction_context.dart';
import 'pseudonym_service.dart';

const int _maxInProgressPolls = 40;
const int _maxInProgressDelayMs = 2000;

class GraphExtractionException implements Exception {
  final String message;
  final int? statusCode;

  const GraphExtractionException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'GraphExtractionException: $message'
      : 'GraphExtractionException ($statusCode): $message';
}

/// Sends one finalized turn to the graph-extraction runtime and returns the
/// patch it found.
///
/// LM-56: the model never sees a known real name. The turn, the recent
/// conversation and the EXISTING ENTITIES / RELATIONS context are swapped
/// with one version of the device's name map ([PseudonymService]); entity
/// and relation ids, which are slugs of real names, are rebuilt from the
/// stand-ins. The patch is swapped back before it is returned, so the ids
/// the app derives from it come from the real names.
class ExtractGraphService {
  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final http.Client _client;
  final PseudonymService _pseudonyms;

  ExtractGraphService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    required PseudonymService pseudonyms,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _pseudonyms = pseudonyms,
        _client = client ?? http.Client();

  Future<GraphPatch> extract({
    required String notebookId,
    required String turnId,
    required String extractorVersion,
    required String text,
    required JournalState state,
    required String mode,
    List<({Speaker role, String text})> recentConversation = const [],
    List<String> retrievedEntityIds = const [],
    FollowUp? answeringFollowUp,
    int tokenBudget = defaultExtractionTokenBudget,
    int maxRetries = 2,
  }) async {
    final trimmed = text.trim();
    if (trimmed.length < 6) return GraphPatch.empty();
    if (_baseUrl.isEmpty) {
      throw StateError('The secure graph-extraction route is not configured');
    }

    final accessToken = await _accessTokenProvider();
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('A signed-in session is required');
    }

    final context = compileExtractionContext(
      transcript: trimmed,
      state: state,
      retrievedEntityIds: retrievedEntityIds,
      recentTurns: recentConversation,
      answeringFollowUp: answeringFollowUp,
      budget: tokenBudget,
    );
    await _pseudonyms.syncGraph(state.entities.values);
    final swapped = await _swapRequest(trimmed, context);
    // Nobody signed in: the map can't swap, so nothing is sent.
    if (swapped == null) throw StateError('A signed-in session is required');
    // The runtime caches a result by turn and extractor version and refuses
    // the same key with different text. The swapped text changes when the
    // map does (a name learned since), so the version carries its hash: a
    // retry of identical text still finds its cached result.
    final version =
        '$extractorVersion#ps-${_fnv64(swapped.text + swapped.contextKey)}';
    final requestBody = jsonEncode({
      'turnId': turnId,
      'extractorVersion': version,
      'text': swapped.text,
      'mode': mode,
      'context': swapped.context,
    });
    final url = Uri.parse(
      '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/extractions',
    );

    var inProgressPolls = 0;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await _client.post(
          url,
          headers: {
            'accept': 'application/json',
            'authorization': 'Bearer $accessToken',
            'content-type': 'application/json',
          },
          body: requestBody,
        );

        if (response.statusCode == 401 || response.statusCode == 403) {
          throw StateError('The signed-in session is no longer valid');
        }
        if (response.statusCode == 409 &&
            inProgressPolls < _maxInProgressPolls) {
          Object? decoded;
          try {
            decoded = jsonDecode(response.body);
          } on FormatException {
            decoded = null;
          }
          if (decoded is Map && decoded['code'] == 'inProgress') {
            final requestedDelay = decoded['retryAfterMs'];
            final delayMs = requestedDelay is num
                ? requestedDelay.toInt().clamp(0, _maxInProgressDelayMs)
                : 500;
            inProgressPolls += 1;
            await Future<void>.delayed(Duration(milliseconds: delayMs));
            // Waiting for the owner is not a failed request and therefore must
            // not consume the ordinary network/provider retry budget.
            attempt -= 1;
            continue;
          }
        }
        if ((response.statusCode == 429 || response.statusCode >= 500) &&
            attempt < maxRetries) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (1 << attempt)),
          );
          continue;
        }
        if (response.statusCode != 200) {
          throw GraphExtractionException(
            'The graph-extraction runtime rejected the request',
            statusCode: response.statusCode,
          );
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic> ||
            decoded['patch'] is! Map<String, dynamic>) {
          throw const FormatException('Invalid graph-extraction response');
        }
        final patch = await _swapBack(
          decoded['patch'] as Map<String, dynamic>,
          swapped.relationIds,
        );
        return filterNoise(patch, extra: {'lumen'});
      } catch (error) {
        if (error is StateError ||
            error is FormatException ||
            error is GraphExtractionException) {
          rethrow;
        }
        if (attempt == maxRetries) rethrow;
      }
    }
    return GraphPatch.empty();
  }

  /// The turn and its context with names swapped, or null when nobody is
  /// signed in. Turns (this one and the recent ones) come from the swap
  /// cache, so each is swapped once; the context's short strings are
  /// swapped with the same version of the map.
  Future<_SwappedRequest?> _swapRequest(
    String text,
    ExtractionContext context,
  ) async {
    final extras = <String>[];
    int take(String value) {
      extras.add(value);
      return extras.length - 1;
    }

    final entityAt = [
      for (final e in context.entities)
        (
          name: take(e.name),
          description: e.description == null ? null : take(e.description!)
        ),
    ];
    final labelAt = [for (final r in context.relations) take(r.label)];
    final followUp = context.answeringFollowUp;
    final followUpAt = followUp == null
        ? null
        : (question: take(followUp.question), reason: take(followUp.reason));

    final result = await _pseudonyms.swapTurns(
      [text, for (final t in context.recentConversation) t.text],
      extras: extras,
    );
    if (result == null) return null;
    final out = result.extras;

    // Ids are slugs of real names: rebuilt from the stand-ins, unique.
    final fakeIds = <String, String>{};
    final usedIds = <String>{};
    String unique(String base, Set<String> used) {
      var id = base.isEmpty ? 'e' : base;
      for (var n = 2; !used.add(id); n++) {
        id = '$base-$n';
      }
      return id;
    }

    final entities = <Map<String, dynamic>>[];
    for (var i = 0; i < context.entities.length; i++) {
      final e = context.entities[i];
      final name = out[entityAt[i].name];
      final id = unique(slugify(name), usedIds);
      fakeIds[e.id] = id;
      entities.add({
        'id': id,
        'name': name,
        'type': e.type.name,
        if (entityAt[i].description != null)
          'description': out[entityAt[i].description!],
      });
    }
    final relationIds = <String, String>{};
    final usedRelationIds = <String>{};
    final relations = <Map<String, dynamic>>[];
    for (var i = 0; i < context.relations.length; i++) {
      final r = context.relations[i];
      final source = fakeIds[r.source] ?? 'unknown';
      final target = fakeIds[r.target] ?? 'unknown';
      final label = out[labelAt[i]];
      final id =
          unique('${source}__${slugify(label)}__$target', usedRelationIds);
      relationIds[id] = r.id;
      relations
          .add({'id': id, 'source': source, 'target': target, 'label': label});
    }
    final recent = [
      for (var i = 0; i < context.recentConversation.length; i++)
        {
          'role': context.recentConversation[i].role.name,
          'text': result.turns[i + 1],
        },
    ];
    final swappedContext = {
      'entities': entities,
      'relations': relations,
      'recentConversation': recent,
      'answeringFollowUp': followUpAt == null
          ? null
          : {
              'question': out[followUpAt.question],
              'reason': out[followUpAt.reason],
            },
    };
    return _SwappedRequest(
      text: result.turns.first,
      context: swappedContext,
      contextKey: jsonEncode(swappedContext),
      relationIds: relationIds,
    );
  }

  /// The model's patch with the stand-ins swapped back: names, descriptions,
  /// metadata, questions and labels. `supersedes` holds relation ids the
  /// request offered; each is mapped back to the real id, and one the
  /// request never offered is dropped.
  Future<GraphPatch> _swapBack(
    Map<String, dynamic> patch,
    Map<String, String> relationIds,
  ) async {
    final supersedes = (patch['supersedes'] as List?) ?? const [];
    final rest = Map<String, dynamic>.of(patch)..remove('supersedes');
    // Through JSON once more: the swap returns loosely typed maps.
    final back = jsonDecode(jsonEncode(await _pseudonyms.rehydrateJson(rest)))
        as Map<String, dynamic>;
    back['supersedes'] = [
      for (final id in supersedes)
        if (id is String && relationIds[id] != null) relationIds[id],
    ];
    return GraphPatch.fromJson(back);
  }
}

class _SwappedRequest {
  const _SwappedRequest({
    required this.text,
    required this.context,
    required this.contextKey,
    required this.relationIds,
  });
  final String text;
  final Map<String, dynamic> context;
  final String contextKey;

  /// Stand-in relation id -> real relation id.
  final Map<String, String> relationIds;
}

/// FNV-1a, 64 bits, as hex: stable across runs and platforms.
String _fnv64(String text) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

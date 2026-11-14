import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/forget_redaction.dart';
import '../logic/memory_removal.dart' show withoutEntity;
import '../logic/noise_filter.dart';
import '../logic/pseudonym/pseudonym_map.dart' show StandInSnapshot;
import '../logic/slugify.dart';
import '../logic/turn_state.dart' show Speaker;
import '../models/follow_up.dart';
import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import 'extraction_context.dart';
import 'model_inputs.dart' show clampText;
import 'pseudonym_service.dart';
import 'shared_log.dart';

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
  final SharedLog? _log;
  final ForgetRedactor? _forgotten;

  ExtractGraphService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    required PseudonymService pseudonyms,
    SharedLog? log,
    ForgetRedactor? forgotten,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
        _pseudonyms = pseudonyms,
        _log = log,
        _forgotten = forgotten,
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
    // The answer can come back after the map moved on (a stand-in retired,
    // a person forgotten): it is dropped and the turn asked for once more,
    // swapped with the map as it is now.
    for (var attempt = 0;; attempt++) {
      try {
        return await _extractOnce(
          notebookId: notebookId,
          turnId: turnId,
          extractorVersion: extractorVersion,
          text: text,
          state: state,
          mode: mode,
          recentConversation: recentConversation,
          retrievedEntityIds: retrievedEntityIds,
          answeringFollowUp: answeringFollowUp,
          tokenBudget: tokenBudget,
          maxRetries: maxRetries,
        );
      } on PseudonymResultStale {
        if (attempt == 1) rethrow;
      }
    }
  }

  Future<GraphPatch> _extractOnce({
    required String notebookId,
    required String turnId,
    required String extractorVersion,
    required String text,
    required JournalState state,
    required String mode,
    required List<({Speaker role, String text})> recentConversation,
    required List<String> retrievedEntityIds,
    required FollowUp? answeringFollowUp,
    required int tokenBudget,
    required int maxRetries,
  }) async {
    // LM-63: a person forgotten in this run is redacted from the turn, the
    // recent conversation and the graph, here, on every attempt: a retry
    // after a forget mid-flight carries the words from before it.
    final forgotten = _forgotten;
    await forgotten?.ensureLoaded();
    if (forgotten != null && !forgotten.isEmpty) {
      text = forgotten.redact(text);
      recentConversation = [
        for (final turn in recentConversation)
          (role: turn.role, text: forgotten.redact(turn.text)),
      ];
      state = forgotten.redactState(state);
      final answering = answeringFollowUp;
      if (answering != null &&
          (forgotten.names(answering.question) ||
              forgotten.names(answering.reason))) {
        answeringFollowUp = null;
      }
    }
    final trimmed = text.trim();
    if (trimmed.length < 6) return GraphPatch.empty();
    // Someone forgotten or removed since [state] was taken (a retry after a
    // forget mid-flight carries the state from before) is left out of the
    // request, and of the map, so nothing can turn their name back.
    final blocked = await _pseudonyms.blockedIds();
    for (final id in blocked) {
      if (state.entities.containsKey(id)) state = withoutEntity(state, id);
    }
    retrievedEntityIds = [
      for (final id in retrievedEntityIds)
        if (!blocked.contains(id)) id,
    ];
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
    // The turn itself could not be swapped safely: nothing to extract from
    // that can be sent.
    if (swapped.text == omittedText) return GraphPatch.empty();
    // The runtime caches a result by turn and extractor version and refuses
    // the same key with different text. The swapped text changes when the
    // map does (a name learned since), so the version carries its hash: a
    // retry of identical text still finds its cached result.
    final version =
        '$extractorVersion#ps-${_fnv64(swapped.text + swapped.contextKey)}';
    final request = {
      'turnId': turnId,
      'extractorVersion': version,
      'text': swapped.text,
      'mode': mode,
      'context': swapped.context,
    };
    // What is logged is the map that is encoded and sent (LM-57); a retry
    // sends the same body, so it is one entry.
    unawaited(_log?.record(notebookId, SharedKind.extraction, request));
    final requestBody = jsonEncode(request);
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
        final patch = _withoutBlocked(
          await _swapBack(decoded['patch'] as Map<String, dynamic>, swapped),
          blocked,
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
    bool usable(int at) => out[at] != omittedText;

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

    // A piece that couldn't be swapped safely is left out: an entity
    // without its name, a relation without its label or an end.
    final entities = <Map<String, dynamic>>[];
    for (var i = 0; i < context.entities.length; i++) {
      final e = context.entities[i];
      if (!usable(entityAt[i].name)) continue;
      final name = _clamp(out[entityAt[i].name], _maxName);
      final id = unique(slugify(name), usedIds);
      fakeIds[e.id] = id;
      final description = entityAt[i].description;
      entities.add({
        'id': id,
        'name': name,
        'type': e.type.name,
        if (description != null && usable(description))
          'description': _clamp(out[description], _maxDescription),
      });
    }
    final relationIds = <String, String>{};
    final usedRelationIds = <String>{};
    final relations = <Map<String, dynamic>>[];
    for (var i = 0; i < context.relations.length; i++) {
      final r = context.relations[i];
      final source = fakeIds[r.source];
      final target = fakeIds[r.target];
      if (source == null || target == null || !usable(labelAt[i])) continue;
      final label = _clamp(out[labelAt[i]], _maxLabel);
      final id =
          unique('${source}__${slugify(label)}__$target', usedRelationIds);
      relationIds[id] = r.id;
      relations
          .add({'id': id, 'source': source, 'target': target, 'label': label});
    }
    final recent = [
      for (var i = 0; i < context.recentConversation.length; i++)
        if (result.turns[i + 1] != omittedText)
          {
            'role': context.recentConversation[i].role.name,
            'text': _clamp(result.turns[i + 1], _maxRecentTurn),
          },
    ];
    final swappedContext = {
      'entities': entities,
      'relations': relations,
      'recentConversation': recent,
      'answeringFollowUp': followUpAt == null ||
              !usable(followUpAt.question) ||
              !usable(followUpAt.reason)
          ? null
          : {
              'question': _clamp(out[followUpAt.question], _maxFollowUp),
              'reason': _clamp(out[followUpAt.reason], _maxFollowUp),
            },
    };
    return _SwappedRequest(
      text: _clamp(result.turns.first, _maxText),
      snapshot: result.snapshot,
      context: swappedContext,
      contextKey: jsonEncode(swappedContext),
      relationIds: relationIds,
    );
  }

  /// [patch] without anything that would re-create a [blocked] entity: the
  /// model may still name them from the user's own words.
  GraphPatch _withoutBlocked(GraphPatch patch, Set<String> blocked) {
    if (blocked.isEmpty) return patch;
    bool gone(String name) => blocked.contains(slugify(name));
    return GraphPatch(
      entities: [
        for (final e in patch.entities)
          if (!gone(e.name)) e,
      ],
      relations: [
        for (final r in patch.relations)
          if (!gone(r.source) && !gone(r.target)) r,
      ],
      supersedes: patch.supersedes,
    );
  }

  /// The model's patch with the stand-ins swapped back: names, descriptions,
  /// metadata, questions and labels, with the stand-ins as they were when
  /// the request was swapped ([PseudonymService.restore]; throws
  /// [PseudonymResultStale] if one no longer stands for the same person).
  /// `supersedes` holds relation ids the request offered; each is mapped
  /// back to the real id, and one the request never offered is dropped.
  Future<GraphPatch> _swapBack(
    Map<String, dynamic> patch,
    _SwappedRequest request,
  ) async {
    final relationIds = request.relationIds;
    final supersedes = (patch['supersedes'] as List?) ?? const [];
    final rest = Map<String, dynamic>.of(patch)..remove('supersedes');
    // Through JSON once more: the swap returns loosely typed maps.
    final back = jsonDecode(
            jsonEncode(await _pseudonyms.restore(request.snapshot, rest)))
        as Map<String, dynamic>;
    back['supersedes'] = [
      for (final id in supersedes)
        if (id is String && relationIds[id] != null) relationIds[id],
    ];
    return GraphPatch.fromJson(back);
  }
}

// The runtime's limits (extract-graph core.mjs validContext / validRequest).
// A stand-in can be longer than the name it replaces: clamped here so a
// long one can't turn into a permanent 400.
const _maxText = 50000;
const _maxName = 200;
const _maxDescription = 1000;
const _maxLabel = 160;
const _maxRecentTurn = 4000;
const _maxFollowUp = 1000;

String _clamp(String text, int max) => clampText(text, max);

class _SwappedRequest {
  const _SwappedRequest({
    required this.text,
    required this.snapshot,
    required this.context,
    required this.contextKey,
    required this.relationIds,
  });
  final String text;
  final StandInSnapshot snapshot;
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

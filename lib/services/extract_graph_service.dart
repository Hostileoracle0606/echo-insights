import 'dart:convert';

import 'package:http/http.dart' as http;

import '../logic/noise_filter.dart';
import '../logic/turn_state.dart' show Speaker;
import '../models/follow_up.dart';
import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import 'extraction_context.dart';

class GraphExtractionException implements Exception {
  final String message;
  final int? statusCode;

  const GraphExtractionException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'GraphExtractionException: $message'
      : 'GraphExtractionException ($statusCode): $message';
}

class ExtractGraphService {
  final String _baseUrl;
  final Future<String?> Function() _accessTokenProvider;
  final http.Client _client;

  ExtractGraphService({
    required String baseUrl,
    required Future<String?> Function() accessTokenProvider,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _accessTokenProvider = accessTokenProvider,
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
    final requestBody = jsonEncode({
      'turnId': turnId,
      'extractorVersion': extractorVersion,
      'text': trimmed,
      'mode': mode,
      'context': _contextToJson(context),
    });
    final url = Uri.parse(
      '$_baseUrl/v1/notebooks/${Uri.encodeComponent(notebookId)}/extractions',
    );

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
        final patch = GraphPatch.fromJson(
          decoded['patch'] as Map<String, dynamic>,
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

  Map<String, dynamic> _contextToJson(ExtractionContext context) => {
        'entities': context.entities
            .map(
              (entity) => {
                'id': entity.id,
                'name': entity.name,
                'type': entity.type.name,
                if (entity.description != null)
                  'description': entity.description,
              },
            )
            .toList(),
        'relations': context.relations
            .map(
              (relation) => {
                'id': relation.id,
                'source': relation.source,
                'target': relation.target,
                'label': relation.label,
              },
            )
            .toList(),
        'recentConversation': context.recentConversation
            .map((turn) => {'role': turn.role.name, 'text': turn.text})
            .toList(),
        'answeringFollowUp': context.answeringFollowUp == null
            ? null
            : {
                'question': context.answeringFollowUp!.question,
                'reason': context.answeringFollowUp!.reason,
              },
      };
}

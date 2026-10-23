import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import '../providers/supabase_provider.dart';

/// Memory retrieval for extraction and the get_relevant_memory tool; tests
/// substitute a fake.
final retrieveMemoryServiceProvider = Provider<RetrieveMemoryService>(
  (ref) => RetrieveMemoryService(ref.watch(supabaseClientProvider)),
);

String _iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, dynamic> _entity(Entity e) => {
      'id': e.id,
      'name': e.name,
      'type': e.type.name,
      if (e.description != null) 'description': e.description,
      'metadata': e.metadata,
      'mentions': e.mentions,
      'firstSeen': _iso(e.firstSeen),
      'lastSeen': _iso(e.lastSeen),
      if (e.questions != null) 'questions': e.questions,
    };

Map<String, dynamic> _relation(Relation r) => {
      'id': r.id,
      'source': r.source,
      'target': r.target,
      'label': r.label,
      'metadata': r.metadata,
      'createdAt': _iso(r.createdAt),
      if (r.supersededAt != null) 'supersededAt': _iso(r.supersededAt!),
    };

Map<String, dynamic> _entry(JournalEntry en) => {
      'id': en.id,
      'text': en.text,
      'createdAt': _iso(en.createdAt),
      'entityIds': en.entityIds,
      'relationIds': en.relationIds,
    };

/// Serialize JournalState into graphloop's GraphState shape (camelCase keys,
/// ISO-8601 UTC timestamps). NOT the Dart models' snake_case toJson() — the
/// edge function's retrieve() reads camelCase (lastSeen, entityIds, …).
/// followUps / askedQuestions are intentionally dropped (retrieval never uses
/// them), matching the web app's toGraphState.
Map<String, dynamic> stateToGraphloop(JournalState state) => {
      'entities': {
        for (final e in state.entities.values) e.id: _entity(e),
      },
      'relations': {
        for (final r in state.relations.values) r.id: _relation(r),
      },
      'entries': state.entries.map(_entry).toList(),
    };

const int retrieveMemoryContractVersion = 1;

/// Successful response from the versioned retrieve-memory interface.
class MemoryRetrieval {
  final String context;
  final List<String> entityIds;

  const MemoryRetrieval({
    required this.context,
    required this.entityIds,
  });

  static const empty = MemoryRetrieval(context: '', entityIds: []);

  factory MemoryRetrieval.fromData(dynamic data) {
    if (data is! Map) {
      throw const FormatException('Invalid retrieve-memory v1 response');
    }
    if (data['version'] != retrieveMemoryContractVersion) {
      throw const FormatException('Unsupported retrieve-memory contract version');
    }
    final context = data['context'];
    final ids = data['entityIds'];
    if (context is! String || ids is! List || ids.any((id) => id is! String)) {
      throw const FormatException('Invalid retrieve-memory v1 response');
    }
    return MemoryRetrieval(
      context: context,
      entityIds: ids.cast<String>().toList(growable: false),
    );
  }
}

/// Calls the retrieve-memory Edge Function. Transport/provider failures degrade
/// to empty memory. Contract mismatches are rejected, logged distinctly, then
/// fail closed so retrieval cannot break journaling.
class RetrieveMemoryService {
  final SupabaseClient _client;

  RetrieveMemoryService(this._client);

  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async =>
      (await retrieveResult(
        query: query,
        notebookId: notebookId,
        state: state,
      ))
          .context;

  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async {
    final q = query.trim();
    if (q.length < 2) return MemoryRetrieval.empty;
    final startedAt = DateTime.now();

    // Non-sensitive telemetry: outcome + counts only, never query/context text.
    void emit(String outcome, int contextLength) => developer.log(
          'outcome=$outcome qLen=${q.length} contextLen=$contextLength '
          'latencyMs=${DateTime.now().difference(startedAt).inMilliseconds}',
          name: 'lumen.memory',
        );

    try {
      final res = await _client.functions.invoke(
        'retrieve-memory',
        body: {
          'query': q,
          'notebookId': notebookId,
          'state': stateToGraphloop(state),
        },
      );
      final result = MemoryRetrieval.fromData(res.data);
      emit(result.context.isEmpty ? 'empty' : 'ok', result.context.length);
      return result;
    } on FormatException {
      emit('contractError', 0);
      return MemoryRetrieval.empty;
    } catch (_) {
      emit('error', 0);
      return MemoryRetrieval.empty;
    }
  }
}

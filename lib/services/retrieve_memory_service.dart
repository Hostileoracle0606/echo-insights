import 'dart:developer' as developer;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';

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

/// Calls the retrieve-memory edge function. Fail-closed: any error returns "".
class RetrieveMemoryService {
  final SupabaseClient _client;

  RetrieveMemoryService(this._client);

  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async {
    final q = query.trim();
    if (q.length < 2) return '';
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
      final data = res.data;
      if (data is Map && data['context'] is String) {
        final context = data['context'] as String;
        emit(context.isEmpty ? 'empty' : 'ok', context.length);
        return context;
      }
      emit('malformed', 0);
      return '';
    } catch (_) {
      emit('error', 0);
      return '';
    }
  }
}

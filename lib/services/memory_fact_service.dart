import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic/context_materialiser.dart' show WorkingFact;

/// EC-03: records a committed turn's facts (record_memory_facts). The
/// database makes every decision (repeat, supersede, history, pinned), so a
/// retry of the same turn adds nothing.
class MemoryFactService {
  MemoryFactService(this._client);
  final SupabaseClient _client;

  Future<void> recordFacts({
    required String notebookId,
    required String entryId,
    required List<Map<String, dynamic>> facts,
  }) async {
    if (facts.isEmpty) return;
    await _client.rpc('record_memory_facts', params: {
      'p_notebook_id': notebookId,
      'p_entry_id': entryId,
      'p_facts': facts,
    });
  }

  /// EC-05: the current facts of [entityIds] for a rebuilt context's working
  /// set (get_current_facts). Malformed rows are skipped.
  Future<List<WorkingFact>> currentFacts(List<String> entityIds) async {
    if (entityIds.isEmpty) return const [];
    final data = await _client.rpc('get_current_facts', params: {
      'p_entity_ids': entityIds,
    });
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (WorkingFact.tryFromJson(row) case final fact?) fact,
    ];
  }
}

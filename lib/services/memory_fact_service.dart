import 'package:supabase_flutter/supabase_flutter.dart';

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
}

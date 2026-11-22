import 'package:supabase_flutter/supabase_flutter.dart';

/// EC-04: the session state record of one conversation (conversation_state).
/// Saved after each finalized turn on the record, read when a conversation
/// is reopened, deleted when it ends.
class ConversationStateService {
  ConversationStateService(this._client);
  final SupabaseClient _client;

  Future<void> save(String notebookId, Map<String, dynamic> state) =>
      _client.rpc('save_conversation_state', params: {
        'p_notebook_id': notebookId,
        'p_state': state,
      });

  Future<Map<String, dynamic>?> load(String notebookId) async {
    final data = await _client.rpc('get_conversation_state', params: {
      'p_notebook_id': notebookId,
    });
    return data is Map<String, dynamic> ? data : null;
  }

  Future<void> clear(String notebookId) =>
      _client.rpc('clear_conversation_state', params: {
        'p_notebook_id': notebookId,
      });
}

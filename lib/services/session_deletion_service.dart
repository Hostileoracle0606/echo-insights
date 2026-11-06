import 'package:supabase_flutter/supabase_flutter.dart';

typedef SessionDeletionRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);

/// "Delete this session" (LM-48): a thin adapter over the `delete_notebook`
/// RPC (see supabase/migrations/20261104000100_complete_deletion.sql), which
/// is owner-checked and removes the session's turns, card, commit requests,
/// the session brief written from it, and the graph rows no other session
/// backs. Nothing here logs or returns what the session held.
class SessionDeletionService {
  SessionDeletionService(SupabaseClient client)
      : _rpc = ((function, params) => client.rpc(function, params: params));

  SessionDeletionService.withRpc(this._rpc);

  final SessionDeletionRpc _rpc;

  /// Deletes [notebookId] and what it alone held. Safe to retry: a session
  /// that is already gone is not an error. Returns whether a session was
  /// deleted by this call.
  Future<bool> deleteSession(String notebookId) async {
    final data = await _rpc('delete_notebook', {'p_notebook_id': notebookId});
    return (data as Map)['deleted'] == true;
  }
}

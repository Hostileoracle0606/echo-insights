import 'package:supabase_flutter/supabase_flutter.dart';

typedef MemoryControlRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);

/// The user's controls over what Lumen keeps (LM-29): a thin adapter over
/// the `edit_entity_description` / `remove_entity` RPCs (see
/// supabase/migrations/20261023000100_memory_control.sql). Both act on every
/// notebook the signed-in user has, and both bump each affected notebook's
/// revision, so an open notebook reloads its snapshot afterwards.
class MemoryControlService {
  MemoryControlService(SupabaseClient client)
      : _rpc = ((function, params) => client.rpc(function, params: params));

  MemoryControlService.withRpc(this._rpc);

  final MemoryControlRpc _rpc;

  /// Replaces the entity's description everywhere with [text] (capped at
  /// 800 characters server-side) and marks it user-written, so extraction
  /// never overwrites it. Returns how many notebooks changed.
  Future<int> editDescription(String entityId, String text) async {
    final data = await _rpc('edit_entity_description', {
      'p_entity_id': entityId,
      'p_text': text,
    });
    return ((data as Map)['updatedNotebooks'] as num).toInt();
  }

  /// Deletes the entity, its relations and embeddings from every notebook,
  /// and suppresses the id so no later conversation adds it back. Safe to
  /// retry. Returns how many notebooks it was removed from.
  Future<int> removeEntity(String entityId) async {
    final data = await _rpc('remove_entity', {'p_entity_id': entityId});
    return ((data as Map)['removedFrom'] as num).toInt();
  }
}

import 'package:supabase_flutter/supabase_flutter.dart';

typedef MemoryControlRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);

/// What forgetting a person would remove, from `forget_entity_preview`
/// (LM-49), and what `forget_entity` reports it removed. Counts only: no
/// names or text.
class ForgetPreview {
  const ForgetPreview({
    required this.notebooks,
    required this.relations,
    required this.followUps,
    required this.askedQuestions,
    required this.cards,
    required this.briefDeleted,
  });

  factory ForgetPreview.fromJson(Map<dynamic, dynamic> json) => ForgetPreview(
        notebooks: (json['notebooks'] as num?)?.toInt() ?? 0,
        relations: (json['relations'] as num?)?.toInt() ?? 0,
        followUps: (json['followUps'] as num?)?.toInt() ?? 0,
        askedQuestions: (json['askedQuestions'] as num?)?.toInt() ?? 0,
        cards: (json['cards'] as num?)?.toInt() ?? 0,
        briefDeleted: json['briefDeleted'] == true,
      );

  final int notebooks;
  final int relations;
  final int followUps;
  final int askedQuestions;
  final int cards;
  final bool briefDeleted;
}

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

  /// What [forgetEntity] would remove. Changes nothing.
  Future<ForgetPreview> previewForget(String entityId) async {
    final data = await _rpc('forget_entity_preview', {'p_entity_id': entityId});
    return ForgetPreview.fromJson(data as Map);
  }

  /// Forgets the entity in every notebook: its relations, embeddings,
  /// follow-ups and asked questions go, a brief that mentions it is deleted,
  /// its name is redacted from cards, and a hashed suppression keeps later
  /// conversations from adding it back. Safe to retry.
  Future<ForgetPreview> forgetEntity(String entityId) async {
    final data = await _rpc('forget_entity', {'p_entity_id': entityId});
    return ForgetPreview.fromJson(data as Map);
  }
}

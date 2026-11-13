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
    this.transcriptPassages = 0,
    this.transcriptPassagesCapped = false,
    this.eraseAvailable = false,
    this.eraseJobId,
  });

  factory ForgetPreview.fromJson(Map<dynamic, dynamic> json) => ForgetPreview(
        notebooks: (json['notebooks'] as num?)?.toInt() ?? 0,
        relations: (json['relations'] as num?)?.toInt() ?? 0,
        followUps: (json['followUps'] as num?)?.toInt() ?? 0,
        askedQuestions: (json['askedQuestions'] as num?)?.toInt() ?? 0,
        cards: (json['cards'] as num?)?.toInt() ?? 0,
        briefDeleted: json['briefDeleted'] == true,
        transcriptPassages: (json['transcriptPassages'] as num?)?.toInt() ?? 0,
        transcriptPassagesCapped: json['transcriptPassagesCapped'] == true,
        eraseAvailable: json['eraseAvailable'] == true,
        eraseJobId: json['eraseJobId'] as String?,
      );

  final int notebooks;
  final int relations;
  final int followUps;
  final int askedQuestions;
  final int cards;
  final bool briefDeleted;

  /// Saved turns and journal entries that name the person: what "also
  /// erase them from my saved transcripts" would rewrite. The server stops
  /// counting at 500 ([transcriptPassagesCapped]).
  final int transcriptPassages;
  final bool transcriptPassagesCapped;

  /// False for a one-word name (R34): erasing it would change ordinary
  /// words too. An older server never offers it.
  final bool eraseAvailable;

  /// From `forget_entity(id, true)`: the queued erase, run by [MemoryControlService.eraseStep].
  final String? eraseJobId;
}

/// One passage the erase would change: as it is, and as it would be.
class ErasePassage {
  const ErasePassage(this.before, this.after);
  final String before;
  final String after;
}

/// Where a queued erase is after a step (R35).
class EraseStep {
  const EraseStep({
    required this.total,
    required this.remaining,
    required this.finished,
  });
  final int total;
  final int remaining;
  final bool finished;
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
  ///
  /// With [eraseTranscripts], the server forgets and queues an erase of the
  /// name (as saved, two or more words) from the user's saved turns and
  /// entries, Lumen's lines included; [ForgetPreview.eraseJobId] names it.
  /// The forget never waits for or fails because of the erase. A one-word
  /// name is refused (22023) and nothing is forgotten.
  Future<ForgetPreview> forgetEntity(String entityId,
      {bool eraseTranscripts = false}) async {
    final data = await _rpc('forget_entity', {
      'p_entity_id': entityId,
      if (eraseTranscripts) 'p_erase_transcripts': true,
    });
    return ForgetPreview.fromJson(data as Map);
  }

  /// Up to [limit] passages the erase would change (R34's confirmation).
  Future<List<ErasePassage>> eraseSample(String entityId,
      {int limit = 3}) async {
    final data = await _rpc('forget_erase_sample', {
      'p_entity_id': entityId,
      'p_limit': limit,
    });
    final passages = (data as Map)['passages'] as List? ?? const [];
    return [
      for (final p in passages.cast<Map>())
        ErasePassage(p['before'] as String, p['after'] as String),
    ];
  }

  /// Checks up to [batch] more rows of erase [jobId] (each call well under a
  /// second). A finished or unknown job comes back finished.
  Future<EraseStep> eraseStep(String jobId, {int batch = 300}) async {
    final data = await _rpc('forget_erase_step', {
      'p_job_id': jobId,
      'p_batch': batch,
    }) as Map;
    return EraseStep(
      total: (data['total'] as num?)?.toInt() ?? 0,
      remaining: (data['remaining'] as num?)?.toInt() ?? 0,
      finished: data['finished'] == true,
    );
  }

  /// The caller's erases that haven't finished, to resume.
  Future<List<String>> pendingErases() async {
    final data = await _rpc('forget_erase_pending', {});
    return [
      for (final job in (data as List? ?? const []).cast<Map>())
        job['id'] as String,
    ];
  }
}

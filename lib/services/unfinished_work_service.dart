import 'package:supabase_flutter/supabase_flutter.dart';

typedef UnfinishedWorkRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);

/// A notebook whose card is absent, older than its revision, or only a
/// draft at it (LM-103). Ids and numbers only.
class UnfinishedCard {
  const UnfinishedCard({
    required this.notebookId,
    required this.revision,
    this.cardRevision,
    this.draft = false,
  });

  final String notebookId;
  final int revision;

  /// Null when the notebook has no card at all.
  final int? cardRevision;
  final bool draft;

  @override
  bool operator ==(Object other) =>
      other is UnfinishedCard &&
      other.notebookId == notebookId &&
      other.revision == revision &&
      other.cardRevision == cardRevision &&
      other.draft == draft;

  @override
  int get hashCode => Object.hash(notebookId, revision, cardRevision, draft);

  @override
  String toString() =>
      'UnfinishedCard($notebookId, r$revision, card r$cardRevision'
      '${draft ? ', draft' : ''})';
}

/// The latest just-talk notebook, with no brief at its revision.
class UnfinishedBrief {
  const UnfinishedBrief({required this.notebookId, required this.revision});

  final String notebookId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is UnfinishedBrief &&
      other.notebookId == notebookId &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(notebookId, revision);

  @override
  String toString() => 'UnfinishedBrief($notebookId, r$revision)';
}

/// A notebook with [missing] of its [entityCount] entities lacking a
/// search vector. Stale content hashes are not counted (embed-reconcile).
class UnfinishedVectors {
  const UnfinishedVectors({
    required this.notebookId,
    required this.entityCount,
    required this.missing,
  });

  final String notebookId;
  final int entityCount;
  final int missing;

  @override
  bool operator ==(Object other) =>
      other is UnfinishedVectors &&
      other.notebookId == notebookId &&
      other.entityCount == entityCount &&
      other.missing == missing;

  @override
  int get hashCode => Object.hash(notebookId, entityCount, missing);

  @override
  String toString() =>
      'UnfinishedVectors($notebookId, $missing of $entityCount)';
}

/// A transcript erase job with batches left; [nextBatch] is the batch
/// number `forget_erase_batch` expects next.
class UnfinishedErase {
  const UnfinishedErase({
    required this.jobId,
    required this.nextBatch,
    required this.rewritten,
  });

  final String jobId;
  final int nextBatch;
  final int rewritten;

  @override
  bool operator ==(Object other) =>
      other is UnfinishedErase &&
      other.jobId == jobId &&
      other.nextBatch == nextBatch &&
      other.rewritten == rewritten;

  @override
  int get hashCode => Object.hash(jobId, nextBatch, rewritten);

  @override
  String toString() => 'UnfinishedErase($jobId, batch $nextBatch)';
}

/// What `get_unfinished_work()` reports for the signed-in user: the
/// server-side steps still to finish. Each list is newest first; cards and
/// vectors are capped at 50 and [truncated] says when more exist.
class UnfinishedWork {
  const UnfinishedWork({
    this.cards = const [],
    this.briefs = const [],
    this.vectors = const [],
    this.erase = const [],
    this.truncated = false,
  });

  static const UnfinishedWork empty = UnfinishedWork();

  final List<UnfinishedCard> cards;
  final List<UnfinishedBrief> briefs;
  final List<UnfinishedVectors> vectors;
  final List<UnfinishedErase> erase;
  final bool truncated;

  bool get isEmpty =>
      cards.isEmpty && briefs.isEmpty && vectors.isEmpty && erase.isEmpty;

  /// Tolerant: a row missing an id or a number is dropped, never guessed.
  factory UnfinishedWork.fromJson(Object? json) {
    if (json is! Map) return empty;
    List<Map> rows(String key) => [
          for (final row in json[key] is List ? json[key] as List : const [])
            if (row is Map) row,
        ];
    int? number(Object? value) => value is num ? value.toInt() : null;

    return UnfinishedWork(
      cards: [
        for (final row in rows('cards'))
          if (row['notebookId'] is String && number(row['revision']) != null)
            UnfinishedCard(
              notebookId: row['notebookId'] as String,
              revision: number(row['revision'])!,
              cardRevision: number(row['cardRevision']),
              draft: row['draft'] == true,
            ),
      ],
      briefs: [
        for (final row in rows('briefs'))
          if (row['notebookId'] is String && number(row['revision']) != null)
            UnfinishedBrief(
              notebookId: row['notebookId'] as String,
              revision: number(row['revision'])!,
            ),
      ],
      vectors: [
        for (final row in rows('vectors'))
          if (row['notebookId'] is String &&
              number(row['entityCount']) != null &&
              number(row['missing']) != null)
            UnfinishedVectors(
              notebookId: row['notebookId'] as String,
              entityCount: number(row['entityCount'])!,
              missing: number(row['missing'])!,
            ),
      ],
      erase: [
        for (final row in rows('erase'))
          if (row['id'] is String && number(row['nextBatch']) != null)
            UnfinishedErase(
              jobId: row['id'] as String,
              nextBatch: number(row['nextBatch'])!,
              rewritten: number(row['rewritten']) ?? 0,
            ),
      ],
      truncated: json['truncated'] == true,
    );
  }
}

/// Thin adapter over the owner-scoped `get_unfinished_work()` RPC
/// (supabase/migrations/20261116000200_unfinished_work.sql).
class UnfinishedWorkService {
  UnfinishedWorkService(SupabaseClient client)
      : _rpc = ((function, params) => client.rpc(function, params: params));

  UnfinishedWorkService.withRpc(this._rpc);

  final UnfinishedWorkRpc _rpc;

  Future<UnfinishedWork> load() async =>
      UnfinishedWork.fromJson(await _rpc('get_unfinished_work', const {}));
}

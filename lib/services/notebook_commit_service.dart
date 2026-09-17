import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/entity.dart';
import '../models/follow_up.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';

/// The one write seam for a notebook's journal/graph data. PostgreSQL owns
/// ownership, write order, UUID generation, atomicity, and retry safety —
/// this service is a thin adapter over the `commit_notebook` /
/// `get_notebook_snapshot` RPCs (see
/// supabase/migrations/20260821000000_notebook_commit_module.sql). Mirrors
/// src/lib/notebook-commit.ts on the web side: same wire contract, same two
/// entry points, so both clients are adapters over one server-owned module.
class NotebookCommitService {
  final SupabaseClient _client;

  const NotebookCommitService(this._client);

  /// One requestId per logical write; keep the SAME id across retries.
  static String newRequestId() => const Uuid().v4();

  Future<CommitOutcome> commitNotebook({
    required String notebookId,
    required int expectedRevision,
    required String requestId,
    required NotebookChange change,
  }) async {
    final data = await _client.rpc('commit_notebook', params: {
      'p_notebook_id': notebookId,
      'p_expected_revision': expectedRevision,
      'p_request_id': requestId,
      'p_change': change.toJson(),
    });
    return CommitOutcome.fromJson(data as Map<String, dynamic>);
  }

  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async {
    final data = await _client.rpc('get_notebook_snapshot', params: {
      'p_notebook_id': notebookId,
    });
    if (data == null) return null; // not found, or not owned by the caller
    return NotebookSnapshot.fromJson(data as Map<String, dynamic>);
  }
}

/// A delta, not another full-notebook snapshot. Sealed so a caller handling
/// a [NotebookChange] gets an exhaustiveness check from the analyzer, the
/// same guarantee TypeScript's discriminated union gives the web client.
sealed class NotebookChange {
  const NotebookChange();
  Map<String, dynamic> toJson();
}

class FollowUpContent {
  final String question;
  final String reason;
  final List<String> targetEntityIds;
  const FollowUpContent({
    required this.question,
    required this.reason,
    required this.targetEntityIds,
  });
  factory FollowUpContent.fromJson(Map<String, dynamic> json) =>
      FollowUpContent(
        question: json['question'] as String,
        reason: json['reason'] as String,
        targetEntityIds: (json['targetEntityIds'] as List).cast<String>(),
      );
  Map<String, dynamic> toJson() => {
        'question': question,
        'reason': reason,
        'targetEntityIds': targetEntityIds
      };
}

class AskedQuestionContent {
  final String question;
  final List<String> targetEntityIds;
  const AskedQuestionContent(
      {required this.question, required this.targetEntityIds});
  factory AskedQuestionContent.fromJson(Map<String, dynamic> json) =>
      AskedQuestionContent(
        question: json['question'] as String,
        targetEntityIds: (json['targetEntityIds'] as List).cast<String>(),
      );
  Map<String, dynamic> toJson() =>
      {'question': question, 'targetEntityIds': targetEntityIds};
}

class ApplyTurnChange extends NotebookChange {
  final String entryText;
  final List<String> entryEntityIds;
  final List<String> entryRelationIds;
  final List<Entity> entities;
  final List<Relation> relations;
  final FollowUpContent? followUp;
  final AskedQuestionContent? askedQuestion;

  const ApplyTurnChange({
    required this.entryText,
    required this.entryEntityIds,
    required this.entryRelationIds,
    required this.entities,
    required this.relations,
    this.followUp,
    this.askedQuestion,
  });

  factory ApplyTurnChange.fromJson(Map<String, dynamic> json) {
    if (json['kind'] != 'applyTurn') {
      throw const FormatException('Invalid apply-turn change');
    }
    final entry = (json['entry'] as Map).cast<String, dynamic>();
    return ApplyTurnChange(
      entryText: entry['text'] as String,
      entryEntityIds: (entry['entityIds'] as List).cast<String>(),
      entryRelationIds: (entry['relationIds'] as List).cast<String>(),
      entities: (json['entities'] as List)
          .map((value) =>
              Entity.fromJson((value as Map).cast<String, dynamic>()))
          .toList(growable: false),
      relations: (json['relations'] as List)
          .map((value) =>
              Relation.fromJson((value as Map).cast<String, dynamic>()))
          .toList(growable: false),
      followUp: json['followUp'] is Map
          ? FollowUpContent.fromJson(
              (json['followUp'] as Map).cast<String, dynamic>(),
            )
          : null,
      askedQuestion: json['askedQuestion'] is Map
          ? AskedQuestionContent.fromJson(
              (json['askedQuestion'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'applyTurn',
        'entry': {
          'text': entryText,
          'entityIds': entryEntityIds,
          'relationIds': entryRelationIds,
        },
        'entities': entities.map((e) => e.toJson()).toList(),
        'relations': relations.map((r) => r.toJson()).toList(),
        if (followUp != null) 'followUp': followUp!.toJson(),
        if (askedQuestion != null) 'askedQuestion': askedQuestion!.toJson(),
      };
}

class AnswerFollowUpChange extends NotebookChange {
  final String followUpId;
  const AnswerFollowUpChange(this.followUpId);

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'answerFollowUp', 'followUpId': followUpId};
}

class ClearNotebookChange extends NotebookChange {
  const ClearNotebookChange();

  @override
  Map<String, dynamic> toJson() => {'kind': 'clearNotebook'};
}

/// The server's response to a commit attempt. Sealed for the same
/// exhaustiveness reason as [NotebookChange] — callers switch on it rather
/// than checking a status string.
sealed class CommitOutcome {
  const CommitOutcome();

  factory CommitOutcome.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    switch (status) {
      case 'committed':
        final ids = json['ids'] as Map<String, dynamic>? ?? const {};
        return CommitCommitted(
          requestId: json['requestId'] as String,
          revision: (json['revision'] as num).toInt(),
          entryId: ids['entryId'] as String?,
          followUpId: ids['followUpId'] as String?,
        );
      case 'conflict':
        return CommitConflict(
            currentRevision: (json['currentRevision'] as num).toInt());
      case 'rejected':
        return CommitRejected(code: json['code'] as String);
      default:
        throw StateError('unknown commit outcome status: $status');
    }
  }
}

class CommitCommitted extends CommitOutcome {
  final String requestId;
  final int revision;
  final String? entryId;
  final String? followUpId;
  const CommitCommitted({
    required this.requestId,
    required this.revision,
    this.entryId,
    this.followUpId,
  });
}

class CommitConflict extends CommitOutcome {
  final int currentRevision;
  const CommitConflict({required this.currentRevision});
}

/// [code] is one of: invalidChange | notFound | requestIdReused | commitFailed.
class CommitRejected extends CommitOutcome {
  final String code;
  const CommitRejected({required this.code});
}

class NotebookSnapshot {
  final String notebookId;
  final int revision;
  final JournalState state;
  const NotebookSnapshot({
    required this.notebookId,
    required this.revision,
    required this.state,
  });

  factory NotebookSnapshot.fromJson(Map<String, dynamic> json) {
    final stateJson = json['state'] as Map<String, dynamic>;
    final entriesJson = (stateJson['entries'] as List<dynamic>?) ?? const [];
    final entitiesJson =
        (stateJson['entities'] as Map<String, dynamic>?) ?? const {};
    final relationsJson =
        (stateJson['relations'] as Map<String, dynamic>?) ?? const {};
    final followUpsJson =
        (stateJson['followUps'] as List<dynamic>?) ?? const [];
    return NotebookSnapshot(
      notebookId: json['notebookId'] as String,
      revision: (json['revision'] as num).toInt(),
      state: JournalState(
        entries: entriesJson
            .map((e) => JournalEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        entities: {
          for (final entry in entitiesJson.entries)
            entry.key: Entity.fromJson(entry.value as Map<String, dynamic>),
        },
        relations: {
          for (final entry in relationsJson.entries)
            entry.key: Relation.fromJson(entry.value as Map<String, dynamic>),
        },
        followUps: followUpsJson
            .map((f) => FollowUp.fromJson(f as Map<String, dynamic>))
            .toList(),
      ),
    );
  }
}

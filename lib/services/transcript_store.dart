import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic/turn_state.dart';

/// A notebook's conversation on the server (`conversation_turns`), so it
/// survives reinstalls and shows on every device (plan: Phase 3).
abstract interface class TranscriptStore {
  /// The notebook's most recent turns, oldest first.
  Future<List<ConversationTurn>> load(String notebookId, {int limit = 500});

  /// Saves one finalized turn. Idempotent: a retry of a saved turn is a
  /// no-op.
  Future<void> save(String notebookId, ConversationTurn turn);
}

class SupabaseTranscriptStore implements TranscriptStore {
  SupabaseTranscriptStore(this._client);

  final SupabaseClient _client;
  static const _table = 'conversation_turns';

  @override
  Future<List<ConversationTurn>> load(
    String notebookId, {
    int limit = 500,
  }) async {
    final rows = await _client
        .from(_table)
        .select('turn_id, speaker, text, spoken_at')
        .eq('notebook_id', notebookId)
        .order('spoken_at', ascending: false)
        .limit(limit);
    return [
      for (final row in rows.reversed) turnFromRow(row),
    ];
  }

  @override
  Future<void> save(String notebookId, ConversationTurn turn) async {
    await _client.from(_table).upsert(
          turnToRow(notebookId, turn),
          onConflict: 'notebook_id,turn_id',
          ignoreDuplicates: true,
        );
  }
}

/// The row for [turn]; `user_id` defaults to the caller on the server.
Map<String, dynamic> turnToRow(String notebookId, ConversationTurn turn) => {
      'notebook_id': notebookId,
      'turn_id': turn.turnId,
      'speaker': turn.role == Speaker.user ? 'user' : 'assistant',
      'text': turn.text,
      'spoken_at': DateTime.parse(turn.startedAt).toUtc().toIso8601String(),
    };

ConversationTurn turnFromRow(Map<String, dynamic> row) {
  final spokenAt =
      DateTime.parse(row['spoken_at'] as String).toUtc().toIso8601String();
  return ConversationTurn(
    turnId: row['turn_id'] as String,
    role: row['speaker'] == 'user' ? Speaker.user : Speaker.assistant,
    text: row['text'] as String,
    createdAt: spokenAt,
    startedAt: spokenAt,
  );
}

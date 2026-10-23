import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/conversation_mode.dart';
import '../models/notebook.dart';

/// Notebook lifecycle only (create/list/end) — reads and writes of a
/// notebook's journal/graph data go through NotebookCommitService instead
/// (commit_notebook / get_notebook_snapshot), never direct table access.
class SupabaseService {
  final SupabaseClient _client;

  SupabaseService(this._client);

  Future<void> signInWithEmail(String email, String password) =>
      _client.auth.signInWithPassword(email: email, password: password);

  Future<void> signUpWithEmail(String email, String password) =>
      _client.auth.signUp(email: email, password: password);

  Future<void> signOut() => _client.auth.signOut();

  User? get currentUser => _client.auth.currentUser;

  Future<Notebook?> ensureActiveNotebook() async {
    final userId = currentUser?.id;
    if (userId == null) return null;

    final res = await _client
        .from('notebooks')
        .select()
        .eq('user_id', userId)
        .isFilter('ended_at', null)
        .order('started_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (res != null) return Notebook.fromJson(res);

    final created = await _client
        .from('notebooks')
        .insert({
          'user_id': userId,
          'title': 'Untitled',
          // started_at is NOT NULL with no DB default (unlike created_at); the
          // web client sets it explicitly too. Omitting it fails the insert.
          'started_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select()
        .single();
    return Notebook.fromJson(created);
  }

  Future<List<Notebook>> listNotebooks() async {
    final userId = currentUser?.id;
    if (userId == null) return const [];

    final rows = await _client
        .from('notebooks')
        .select()
        .eq('user_id', userId)
        .order('started_at', ascending: false);

    return (rows as List<dynamic>)
        .map((row) => Notebook.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  Future<Notebook?> createNotebook({
    ConversationMode mode = ConversationMode.justTalk,
    Map<String, dynamic> context = const {},
  }) async {
    final userId = currentUser?.id;
    if (userId == null) return null;

    final created = await _client
        .from('notebooks')
        .insert(newNotebookRow(
          userId: userId,
          startedAt: DateTime.now(),
          conversationMode: mode,
          modeContext: context,
        ))
        .select()
        .single();
    return Notebook.fromJson(created);
  }

  /// The row [createNotebook] inserts.
  @visibleForTesting
  static Map<String, dynamic> newNotebookRow({
    required String userId,
    required DateTime startedAt,
    ConversationMode conversationMode = ConversationMode.justTalk,
    Map<String, dynamic> modeContext = const {},
  }) =>
      {
        'user_id': userId,
        'title': 'Untitled',
        // started_at is NOT NULL with no DB default (unlike created_at); the
        // web client sets it explicitly too. Omitting it fails the insert.
        'started_at': startedAt.toUtc().toIso8601String(),
        'conversation_mode': conversationMode.wireName,
        'mode_context': modeContext,
      };

  Future<void> endNotebook(String notebookId) async {
    await _client.from('notebooks').update({
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', notebookId);
  }
}

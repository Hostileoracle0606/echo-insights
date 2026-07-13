import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entity.dart';
import '../models/follow_up.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/notebook.dart';
import '../models/relation.dart';

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

  Future<Notebook?> createNotebook() async {
    final userId = currentUser?.id;
    if (userId == null) return null;

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

  Future<void> endNotebook(String notebookId) async {
    await _client.from('notebooks').update({
      'ended_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', notebookId);
  }

  Future<JournalState> loadState(String notebookId) async {
    final results = await Future.wait([
      _client.from('journal_entries').select().eq('notebook_id', notebookId),
      _client.from('entities').select().eq('notebook_id', notebookId),
      _client.from('relations').select().eq('notebook_id', notebookId),
      _client.from('follow_ups').select().eq('notebook_id', notebookId),
    ]);

    final entries = (results[0] as List<dynamic>)
        .map((row) => JournalEntry.fromJson(row as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final entities = {
      for (final row in results[1] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: Entity.fromJson(row),
    };
    final relations = {
      for (final row in results[2] as List<dynamic>)
        (row as Map<String, dynamic>)['id'] as String: Relation.fromJson(row),
    };
    final followUps = (results[3] as List<dynamic>)
        .map((row) => FollowUp.fromJson(row as Map<String, dynamic>))
        .toList();

    return JournalState(
      entries: entries,
      entities: entities,
      relations: relations,
      followUps: followUps,
    );
  }

  Future<void> saveState(String notebookId, JournalState state) async {
    final userId = currentUser?.id;
    if (userId == null) return;
    await _client
        .from('journal_entries')
        .delete()
        .eq('notebook_id', notebookId);
    await _client.from('entities').delete().eq('notebook_id', notebookId);
    await _client.from('relations').delete().eq('notebook_id', notebookId);
    await _client.from('follow_ups').delete().eq('notebook_id', notebookId);

    if (state.entries.isNotEmpty) {
      await _client.from('journal_entries').insert(
            state.entries
                .map((entry) =>
                    {...entry.toJson(), 'notebook_id': notebookId, 'user_id': userId})
                .toList(),
          );
    }
    if (state.entities.isNotEmpty) {
      await _client.from('entities').insert(
            state.entities.values
                .map((entity) => {
                      ...entity.toJson(),
                      'notebook_id': notebookId,
                      'user_id': userId,
                    })
                .toList(),
          );
    }
    if (state.relations.isNotEmpty) {
      await _client.from('relations').insert(
            state.relations.values
                .map(
                  (relation) => {
                    ...relation.toJson(),
                    'notebook_id': notebookId,
                    'user_id': userId,
                  },
                )
                .toList(),
          );
    }
    if (state.followUps.isNotEmpty) {
      await _client.from('follow_ups').insert(
            state.followUps
                .map(
                  (followUp) => {
                    ...followUp.toJson(),
                    'notebook_id': notebookId,
                    'user_id': userId,
                  },
                )
                .toList(),
          );
    }

    await _client.from('notebooks').update({
      'entity_count': state.entities.length,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', notebookId);
  }
}

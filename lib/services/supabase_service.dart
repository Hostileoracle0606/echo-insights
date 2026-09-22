import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/notebook.dart';
import 'turn_journal_service.dart';

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

  /// Sends a password recovery email. Supabase answers the same way whether
  /// or not an account exists, so the caller never learns which emails are
  /// registered. The link opens [redirectTo] (the web app's /auth/reset),
  /// where the new password is set.
  Future<void> requestPasswordReset(String email, {String? redirectTo}) =>
      _client.auth.resetPasswordForEmail(
        email,
        redirectTo: (redirectTo == null || redirectTo.isEmpty) ? null : redirectTo,
      );

  /// Permanently deletes the signed-in account (App Store Guideline
  /// 5.1.1(v)). The delete-account edge function takes the user id from the
  /// caller's JWT, and every server row cascades from the auth user. Local
  /// transcripts are wiped only once the server delete has succeeded, then
  /// the now-invalid session is dropped. A failed call throws and leaves
  /// everything in place.
  Future<void> deleteAccount({required TurnJournalService journal}) async {
    await _client.functions.invoke('delete-account');
    await journal.forgetAll();
    await _client.auth.signOut();
  }

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
}

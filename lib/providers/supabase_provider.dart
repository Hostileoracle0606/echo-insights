import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../env.dart';
import '../services/extract_graph_service.dart';
import '../services/fresh_access_token.dart';
import '../services/memory_control_service.dart';
import '../services/notebook_commit_service.dart';
import '../services/notebook_runtime_service.dart';
import '../services/session_card_service.dart';
import '../services/supabase_service.dart';
import '../services/transcript_store.dart';

final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

TokenSnapshot? _snapshot(Session? session) => session == null
    ? null
    : (accessToken: session.accessToken, expiresAt: session.expiresAt);

/// The runtime and extraction calls authenticate with this: a token that
/// has expired (e.g. at launch, before Supabase's background refresh lands)
/// is refreshed first instead of being sent and rejected with 401.
Future<String?> _accessToken(SupabaseClient client) => freshAccessToken(
      current: () => _snapshot(client.auth.currentSession),
      refresh: () async =>
          _snapshot((await client.auth.refreshSession()).session),
    );

final supabaseServiceProvider = Provider<SupabaseService>((ref) {
  return SupabaseService(ref.watch(supabaseClientProvider));
});

final notebookCommitServiceProvider = Provider<NotebookCommitService>((ref) {
  return NotebookCommitService(ref.watch(supabaseClientProvider));
});

final memoryControlServiceProvider = Provider<MemoryControlService>((ref) {
  return MemoryControlService(ref.watch(supabaseClientProvider));
});

final notebookRuntimeServiceProvider = Provider<NotebookRuntimeService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return NotebookRuntimeService(
    baseUrl: Env.notebookRuntimeUrl,
    accessTokenProvider: () => _accessToken(client),
  );
});

final extractGraphServiceProvider = Provider<ExtractGraphService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ExtractGraphService(
    baseUrl: Env.notebookRuntimeUrl,
    accessTokenProvider: () => _accessToken(client),
  );
});

/// The closing card for a conversation (LM-15): written by the notebook
/// runtime, read back from `session_cards` (owner-only RLS).
final sessionCardServiceProvider = Provider<SessionCardService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SessionCardService(
    baseUrl: Env.notebookRuntimeUrl,
    accessTokenProvider: () => _accessToken(client),
    readCard: (notebookId) async {
      final row = await client
          .from('session_cards')
          .select('card')
          .eq('notebook_id', notebookId)
          .maybeSingle();
      return row?['card'];
    },
  );
});

final transcriptStoreProvider = Provider<TranscriptStore>((ref) {
  return SupabaseTranscriptStore(ref.watch(supabaseClientProvider));
});

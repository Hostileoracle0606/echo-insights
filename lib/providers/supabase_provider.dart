import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../env.dart';
import '../services/extract_graph_service.dart';
import '../services/notebook_commit_service.dart';
import '../services/notebook_runtime_service.dart';
import '../services/supabase_service.dart';
import '../services/transcript_store.dart';

final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

final supabaseServiceProvider = Provider<SupabaseService>((ref) {
  return SupabaseService(ref.watch(supabaseClientProvider));
});

final notebookCommitServiceProvider = Provider<NotebookCommitService>((ref) {
  return NotebookCommitService(ref.watch(supabaseClientProvider));
});

final notebookRuntimeServiceProvider = Provider<NotebookRuntimeService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return NotebookRuntimeService(
    baseUrl: Env.notebookRuntimeUrl,
    accessTokenProvider: () async => client.auth.currentSession?.accessToken,
  );
});

final extractGraphServiceProvider = Provider<ExtractGraphService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ExtractGraphService(
    baseUrl: Env.notebookRuntimeUrl,
    accessTokenProvider: () async => client.auth.currentSession?.accessToken,
  );
});

final transcriptStoreProvider = Provider<TranscriptStore>((ref) {
  return SupabaseTranscriptStore(ref.watch(supabaseClientProvider));
});

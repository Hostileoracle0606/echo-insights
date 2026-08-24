import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/notebook_commit_service.dart';
import '../services/supabase_service.dart';

final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

final supabaseServiceProvider = Provider<SupabaseService>((ref) {
  return SupabaseService(ref.watch(supabaseClientProvider));
});

final notebookCommitServiceProvider = Provider<NotebookCommitService>((ref) {
  return NotebookCommitService(ref.watch(supabaseClientProvider));
});

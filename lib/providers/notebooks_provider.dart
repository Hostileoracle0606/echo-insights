import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notebook.dart';
import 'supabase_provider.dart';

/// The user's notebooks for the dashboard grid, newest session first.
/// autoDispose so each return to the dashboard re-fetches fresh counts.
final notebooksProvider = FutureProvider.autoDispose<List<Notebook>>((ref) {
  return ref.watch(supabaseServiceProvider).listNotebooks();
});

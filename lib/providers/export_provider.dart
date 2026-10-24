import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/markdown_export.dart';
import 'supabase_provider.dart';

/// How a built vault reaches the user: zipped and handed to the iOS share
/// sheet. Tests override it so the real sheet never opens.
final shareVaultProvider = Provider<ShareVault>((ref) => shareVaultZip);

/// The whole user's memory as one vault. No screen uses it yet; LM-16, LM-27
/// or LM-31 will add the entry point.
final allMemoryExportProvider = Provider<AllMemoryExport>((ref) {
  final supabase = ref.watch(supabaseServiceProvider);
  final commits = ref.watch(notebookCommitServiceProvider);
  return AllMemoryExport(
    listNotebooks: supabase.listNotebooks,
    loadNotebookState: (id) async =>
        (await commits.getNotebookSnapshot(id))?.state,
  );
});

import 'dart:isolate';

import '../models/journal_export.dart';
import 'markdown_export.dart';

/// "Export my journal" (LM-52): fetches the whole journal through the
/// `export_my_data` RPC and builds the zip's contents.
///
/// One RPC answering for a long-time user's every notebook could run past the
/// database's statement timeout, so the app asks for [chunkSize] notebooks at
/// a time (the RPC's optional `p_notebook_ids` narrows the caller's own
/// notebooks) and stitches the answers together.
class JournalExportService {
  final Future<dynamic> Function(String function, Map<String, dynamic> params)
  _rpc;

  /// The caller's notebook ids, newest first.
  final Future<List<String>> Function() _listNotebookIds;

  const JournalExportService({
    required Future<dynamic> Function(String, Map<String, dynamic>) rpc,
    required Future<List<String>> Function() listNotebookIds,
    this.chunkSize = 10,
  }) : _rpc = rpc,
       _listNotebookIds = listNotebookIds;

  final int chunkSize;

  /// Fetches every notebook, oldest first. [onProgress] reports notebooks
  /// fetched so far. Errors are rethrown as they are; callers show a fixed
  /// message and must not print them (a parse error can quote content).
  Future<JournalExport> fetch({
    void Function(int done, int total)? onProgress,
  }) async {
    final ids = (await _listNotebookIds()).reversed.toList();
    onProgress?.call(0, ids.length);

    JournalExport? first;
    final notebooks = <ExportedNotebook>[];
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(
        i,
        i + chunkSize > ids.length ? ids.length : i + chunkSize,
      );
      final data = await _rpc('export_my_data', {'p_notebook_ids': chunk});
      final part = JournalExport.fromJson(data as Map<String, dynamic>);
      first ??= part;
      notebooks.addAll(part.notebooks);
      onProgress?.call(notebooks.length.clamp(0, ids.length), ids.length);
    }

    // No notebooks: ask once with no filter, so the file still carries the
    // server's version and timestamp.
    first ??= JournalExport.fromJson(
      await _rpc('export_my_data', const {}) as Map<String, dynamic>,
    );
    return JournalExport(
      version: first.version,
      exportedAt: first.exportedAt,
      notebooks: notebooks,
      extra: first.extra,
    );
  }

  /// Builds the zip's contents off the UI isolate.
  Future<MarkdownVault> build(JournalExport export) =>
      Isolate.run(() => buildJournalExportBundle(export));
}

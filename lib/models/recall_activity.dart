import 'memory_quote.dart';

/// What Lumen last recalled in this session: the entities a memory lookup
/// returned and the quotes (with their ids) that came with them. In memory
/// only. LM-13 (citation cards) and LM-14 (recall rings) read it; nothing
/// renders it yet.
class RecallActivity {
  /// Increases with every recall in the session, so a reader can tell a
  /// repeat of the same entities apart from the previous one.
  final int seq;
  final List<String> entityIds;
  final List<MemoryQuote> quotes;
  final DateTime at;

  const RecallActivity({
    required this.seq,
    required this.entityIds,
    required this.quotes,
    required this.at,
  });
}

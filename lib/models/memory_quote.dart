/// One of the user's own past lines, from another conversation, returned by
/// retrieve-memory v2 (contracts/retrieve-memory-v2.schema.json).
///
/// The ids are for the app (citations, recall rings); the model only ever
/// sees [text] and when it was said.
class MemoryQuote {
  final String entryId;
  final String notebookId;

  /// Best-effort: matched by text on the server, null for older notebooks.
  final String? turnId;
  final DateTime? spokenAt;
  final DateTime createdAt;
  final String notebookTitle;
  final String text;

  const MemoryQuote({
    required this.entryId,
    required this.notebookId,
    required this.turnId,
    required this.spokenAt,
    required this.createdAt,
    required this.notebookTitle,
    required this.text,
  });

  /// When the user said it: the matched turn if known, else the entry.
  DateTime get saidAt => spokenAt ?? createdAt;

  factory MemoryQuote.fromData(dynamic data) {
    if (data is! Map) throw const FormatException('Invalid memory quote');
    final entryId = data['entryId'];
    final notebookId = data['notebookId'];
    final turnId = data['turnId'];
    final spokenAt = data['spokenAt'];
    final createdAt = data['createdAt'];
    final notebookTitle = data['notebookTitle'];
    final text = data['text'];
    if (entryId is! String ||
        notebookId is! String ||
        (turnId != null && turnId is! String) ||
        (spokenAt != null && spokenAt is! String) ||
        createdAt is! String ||
        notebookTitle is! String ||
        text is! String) {
      throw const FormatException('Invalid memory quote');
    }
    // DateTime.parse throws FormatException on a bad timestamp.
    return MemoryQuote(
      entryId: entryId,
      notebookId: notebookId,
      turnId: turnId as String?,
      spokenAt: spokenAt == null ? null : DateTime.parse(spokenAt as String),
      createdAt: DateTime.parse(createdAt),
      notebookTitle: notebookTitle,
      text: text,
    );
  }
}

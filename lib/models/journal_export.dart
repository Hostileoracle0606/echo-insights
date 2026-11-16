import 'entity.dart';
import 'follow_up.dart';
import 'journal_entry.dart';
import 'journal_state.dart';
import 'relation.dart';

/// What `export_my_data()` returns (LM-52): the user's whole journal as one
/// JSON object. Parsing keeps every field the server sent, so
/// `JournalExport.fromJson(json).toJson()` equals `json`: an export never
/// loses data to an older app reading a newer server's shape.
///
/// Timestamps stay the server's strings for the same reason; typed values
/// are built on demand ([ExportedNotebook.state]).
class JournalExport {
  /// The export format. Bumped only for a change old readers can't ignore.
  final int version;
  final String exportedAt;
  final List<ExportedNotebook> notebooks;

  /// Top-level keys this app doesn't know yet.
  final Map<String, dynamic> extra;

  const JournalExport({
    required this.version,
    required this.exportedAt,
    required this.notebooks,
    this.extra = const {},
  });

  /// Throws a [FormatException] naming the missing or mistyped key. Never
  /// quotes a value: the message must be safe to log.
  factory JournalExport.fromJson(Map<String, dynamic> json) {
    final known = {'version', 'exportedAt', 'notebooks'};
    return JournalExport(
      version: _field<int>(json, 'version'),
      exportedAt: _field<String>(json, 'exportedAt'),
      notebooks: [
        for (final n in _field<List<dynamic>>(json, 'notebooks'))
          ExportedNotebook.fromJson(_asMap(n, 'notebooks')),
      ],
      extra: {
        for (final e in json.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'exportedAt': exportedAt,
    'notebooks': [for (final n in notebooks) n.toJson()],
    ...extra,
  };
}

/// One notebook and everything under it. The item lists keep the server's
/// own JSON (the shapes `get_notebook_snapshot` uses); [state] types them.
class ExportedNotebook {
  /// Scalar fields: id, title, titleSource, startedAt, endedAt, ...
  final Map<String, dynamic> fields;
  final List<Map<String, dynamic>> turns;
  final List<Map<String, dynamic>> journalEntries;

  /// The closing card, or null when the notebook never got one.
  final Map<String, dynamic>? card;
  final List<Map<String, dynamic>> entities;
  final List<Map<String, dynamic>> relations;
  final List<Map<String, dynamic>> followUps;
  final List<Map<String, dynamic>> askedQuestions;

  const ExportedNotebook({
    required this.fields,
    required this.turns,
    required this.journalEntries,
    required this.card,
    required this.entities,
    required this.relations,
    required this.followUps,
    required this.askedQuestions,
  });

  static const _listKeys = [
    'turns',
    'journalEntries',
    'entities',
    'relations',
    'followUps',
    'askedQuestions',
  ];

  factory ExportedNotebook.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> items(String key) => [
      for (final item in _field<List<dynamic>>(json, key)) _asMap(item, key),
    ];
    final card = json['card'];
    if (card != null && card is! Map<String, dynamic>) {
      throw const FormatException('Export field "card" has the wrong type');
    }
    _field<String>(json, 'id');
    _field<String>(json, 'title');
    _field<String>(json, 'startedAt');
    return ExportedNotebook(
      fields: {
        for (final e in json.entries)
          if (e.key != 'card' && !_listKeys.contains(e.key)) e.key: e.value,
      },
      turns: items('turns'),
      journalEntries: items('journalEntries'),
      card: card as Map<String, dynamic>?,
      entities: items('entities'),
      relations: items('relations'),
      followUps: items('followUps'),
      askedQuestions: items('askedQuestions'),
    );
  }

  Map<String, dynamic> toJson() => {
    ...fields,
    'turns': turns,
    'journalEntries': journalEntries,
    'card': card,
    'entities': entities,
    'relations': relations,
    'followUps': followUps,
    'askedQuestions': askedQuestions,
  };

  String get id => fields['id'] as String;
  String get title => fields['title'] as String;
  DateTime get startedAt => DateTime.parse(fields['startedAt'] as String);
  String? get summary => fields['summary'] as String?;

  /// The notebook as the app's own state type, which the Markdown renderer
  /// takes. Entries run newest first, as in a snapshot.
  JournalState get state => JournalState(
    entries: [for (final e in journalEntries) JournalEntry.fromJson(e)]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    entities: {
      for (final e in entities) (e['id'] as String): Entity.fromJson(e),
    },
    relations: {
      for (final r in relations) (r['id'] as String): Relation.fromJson(r),
    },
    followUps: [for (final f in followUps) FollowUp.fromJson(f)],
  );
}

T _field<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Export field "$key" is missing or has the wrong type');
}

Map<String, dynamic> _asMap(Object? value, String where) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Export list "$where" holds a non-object');
}

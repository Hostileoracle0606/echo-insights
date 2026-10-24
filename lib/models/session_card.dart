import 'conversation_mode.dart';
import 'entity.dart' show EntityType;

/// One row of "Lumen will remember" on a session card. Chosen on the server
/// from the notebook's graph; [note] is the model's short line about it, or
/// null when it wrote none.
class RememberItem {
  final String entityId;
  final String name;
  final EntityType type;
  final String? note;

  /// True when this conversation is the only one that mentions it.
  final bool isNew;

  const RememberItem({
    required this.entityId,
    required this.name,
    required this.type,
    required this.note,
    required this.isNew,
  });

  factory RememberItem.fromJson(Object? data) {
    if (data is! Map) throw const FormatException('Invalid remember item');
    final entityId = data['entityId'];
    final name = data['name'];
    final type = data['type'];
    final note = data['note'];
    final isNew = data['isNew'];
    if (entityId is! String ||
        name is! String ||
        type is! String ||
        (note != null && note is! String) ||
        isNew is! bool) {
      throw const FormatException('Invalid remember item');
    }
    return RememberItem(
      entityId: entityId,
      name: name,
      type: EntityType.values.asNameMap()[type] ?? EntityType.other,
      note: note as String?,
      isNew: isNew,
    );
  }

  Map<String, dynamic> toJson() => {
        'entityId': entityId,
        'name': name,
        'type': type.name,
        'note': note,
        'isNew': isNew,
      };
}

/// The card a conversation ends with (contracts/session-card-v1.schema.json),
/// stored in `session_cards` and returned by the close route.
///
/// The common fields are typed. Each mode's own fields are kept as they came
/// in [modeFields]; the screens that render a mode type the parts they use
/// (LM-16, LM-36). Only Just talk's [notes] is typed here.
class SessionCard {
  static const _commonKeys = {
    'version',
    'notebookId',
    'conversationMode',
    'sourceRevision',
    'generatedAt',
    'title',
    'summary',
    'remember',
  };

  final int version;
  final String notebookId;
  final ConversationMode conversationMode;

  /// The `notebooks.revision` the card was generated from.
  final int sourceRevision;
  final DateTime generatedAt;
  final String title;
  final String summary;
  final List<RememberItem> remember;

  /// Every field outside the common ones, e.g. `notes` for Just talk or
  /// `wins` and `openItems` for a weekly debrief.
  final Map<String, dynamic> modeFields;

  const SessionCard({
    required this.version,
    required this.notebookId,
    required this.conversationMode,
    required this.sourceRevision,
    required this.generatedAt,
    required this.title,
    required this.summary,
    required this.remember,
    required this.modeFields,
  });

  /// Just talk's notes; empty for every other mode.
  List<String> get notes {
    final value = modeFields['notes'];
    return value is List ? value.whereType<String>().toList() : const [];
  }

  factory SessionCard.fromJson(Object? data) {
    if (data is! Map) throw const FormatException('Invalid session card');
    final version = data['version'];
    final notebookId = data['notebookId'];
    final mode = data['conversationMode'];
    final sourceRevision = data['sourceRevision'];
    final generatedAt = data['generatedAt'];
    final title = data['title'];
    final summary = data['summary'];
    final remember = data['remember'];
    if (version != 1) {
      throw FormatException('Unsupported session card version: $version');
    }
    if (notebookId is! String ||
        mode is! String ||
        sourceRevision is! num ||
        generatedAt is! String ||
        title is! String ||
        summary is! String ||
        remember is! List) {
      throw const FormatException('Invalid session card');
    }
    final conversationMode = ConversationMode.values
        .where((value) => value.wireName == mode)
        .firstOrNull;
    final generated = DateTime.tryParse(generatedAt);
    if (conversationMode == null || generated == null) {
      throw const FormatException('Invalid session card');
    }
    return SessionCard(
      version: 1,
      notebookId: notebookId,
      conversationMode: conversationMode,
      sourceRevision: sourceRevision.toInt(),
      generatedAt: generated,
      title: title,
      summary: summary,
      remember: remember.map(RememberItem.fromJson).toList(growable: false),
      modeFields: Map.unmodifiable({
        for (final entry in data.entries)
          if (entry.key is String && !_commonKeys.contains(entry.key))
            entry.key as String: entry.value,
      }),
    );
  }

  Map<String, dynamic> toJson() => {
        ...modeFields,
        'version': version,
        'notebookId': notebookId,
        'conversationMode': conversationMode.wireName,
        'sourceRevision': sourceRevision,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'title': title,
        'summary': summary,
        'remember': remember.map((item) => item.toJson()).toList(),
      };
}

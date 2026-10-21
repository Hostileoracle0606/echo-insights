import 'package:json_annotation/json_annotation.dart';

import 'conversation_mode.dart';

part 'notebook.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class Notebook {
  final String id;
  final String userId;
  final String title;
  final String titleSource;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int entityCount;
  final String? summary;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Unknown or missing server values fall back to [ConversationMode.justTalk]
  /// so an older or newer schema never fails to parse.
  @JsonKey(
    unknownEnumValue: ConversationMode.justTalk,
    defaultValue: ConversationMode.justTalk,
  )
  final ConversationMode conversationMode;

  /// Per-mode inputs, e.g. `{"weekOf": "2026-10-23"}` for a debrief. No schema
  /// yet; nothing reads it.
  @JsonKey(defaultValue: <String, dynamic>{})
  final Map<String, dynamic> modeContext;

  const Notebook({
    required this.id,
    required this.userId,
    required this.title,
    required this.titleSource,
    required this.startedAt,
    this.endedAt,
    required this.entityCount,
    this.summary,
    required this.createdAt,
    required this.updatedAt,
    this.conversationMode = ConversationMode.justTalk,
    this.modeContext = const {},
  });

  factory Notebook.fromJson(Map<String, dynamic> json) =>
      _$NotebookFromJson(json);
  Map<String, dynamic> toJson() => _$NotebookToJson(this);
}

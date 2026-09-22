import 'package:json_annotation/json_annotation.dart';

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
  });

  factory Notebook.fromJson(Map<String, dynamic> json) =>
      _$NotebookFromJson(json);
  Map<String, dynamic> toJson() => _$NotebookToJson(this);
}

import 'package:json_annotation/json_annotation.dart';

part 'relation.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class Relation {
  final String id;
  final String source;
  final String target;
  final String label;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final DateTime? supersededAt;

  const Relation({
    required this.id,
    required this.source,
    required this.target,
    required this.label,
    required this.metadata,
    required this.createdAt,
    this.supersededAt,
  });

  bool get isActive => supersededAt == null;

  factory Relation.fromJson(Map<String, dynamic> json) =>
      _$RelationFromJson(json);
  Map<String, dynamic> toJson() => _$RelationToJson(this);
}

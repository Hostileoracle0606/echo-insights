import 'package:json_annotation/json_annotation.dart';

part 'journal_entry.g.dart';

@JsonSerializable()
class JournalEntry {
  final String id;
  final String text;
  final DateTime createdAt;
  final List<String> entityIds;
  final List<String> relationIds;

  const JournalEntry({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.entityIds,
    required this.relationIds,
  });

  factory JournalEntry.fromJson(Map<String, dynamic> json) =>
      _$JournalEntryFromJson(json);
  Map<String, dynamic> toJson() => _$JournalEntryToJson(this);
}

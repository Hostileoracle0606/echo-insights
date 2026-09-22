import 'entity.dart';
import 'follow_up.dart';
import 'journal_entry.dart';
import 'relation.dart';

class JournalState {
  final List<JournalEntry> entries;
  final Map<String, Entity> entities;
  final Map<String, Relation> relations;
  final List<FollowUp> followUps;

  const JournalState({
    required this.entries,
    required this.entities,
    required this.relations,
    required this.followUps,
  });

  static JournalState empty() => const JournalState(
        entries: [],
        entities: {},
        relations: {},
        followUps: [],
      );

  JournalState copyWith({
    List<JournalEntry>? entries,
    Map<String, Entity>? entities,
    Map<String, Relation>? relations,
    List<FollowUp>? followUps,
  }) =>
      JournalState(
        entries: entries ?? this.entries,
        entities: entities ?? this.entities,
        relations: relations ?? this.relations,
        followUps: followUps ?? this.followUps,
      );
}

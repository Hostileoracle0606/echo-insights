import 'journal_state.dart';

/// What one committed turn did to the graph — the dock's "Upserting" chip.
/// Mirrors the web's `buildUpsertActivity` (src/routes/index.tsx): the ids the
/// turn's journal entry touched, split into new vs refreshed against the
/// pre-merge state.
class UpsertActivity {
  final int id;
  final List<String> entityNames;
  final int insertedEntities;
  final int updatedEntities;
  final int createdRelations;

  const UpsertActivity({
    required this.id,
    required this.entityNames,
    required this.insertedEntities,
    required this.updatedEntities,
    required this.createdRelations,
  });

  /// Null when the turn touched nothing (the web shows no chip then either).
  static UpsertActivity? between({
    required int id,
    required JournalState prev,
    required JournalState next,
    required String entryId,
  }) {
    final entry = next.entries.where((e) => e.id == entryId).firstOrNull;
    if (entry == null) return null;
    final entityIds = entry.entityIds.toSet();
    final relationIds = entry.relationIds.toSet();
    if (entityIds.isEmpty && relationIds.isEmpty) return null;
    return UpsertActivity(
      id: id,
      entityNames: [
        for (final eid in entityIds)
          if (next.entities[eid] case final entity?) entity.name,
      ],
      insertedEntities:
          entityIds.where((eid) => !prev.entities.containsKey(eid)).length,
      updatedEntities:
          entityIds.where((eid) => prev.entities.containsKey(eid)).length,
      createdRelations:
          relationIds.where((rid) => !prev.relations.containsKey(rid)).length,
    );
  }
}

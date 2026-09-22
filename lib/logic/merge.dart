import '../models/entity.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import '../services/notebook_commit_service.dart';
import 'slugify.dart';

const _maxQuestionsPerEntity = 8;

List<String>? _mergeQuestions(List<String>? existing, List<String>? incoming) {
  if ((existing == null || existing.isEmpty) &&
      (incoming == null || incoming.isEmpty)) {
    return existing;
  }
  final seen = <String>{};
  final merged = <String>[];
  for (final q in [...(incoming ?? []), ...(existing ?? [])]) {
    final key = q.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]+'), '');
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    merged.add(q.trim());
    if (merged.length >= _maxQuestionsPerEntity) break;
  }
  return merged.isEmpty ? null : merged;
}

({JournalState next, String entryId, ApplyTurnChange change}) merge(
  JournalState prev,
  String text,
  GraphPatch patch,
) {
  final now = DateTime.now().toUtc();
  final entities = Map<String, Entity>.from(prev.entities);
  final relations = Map<String, Relation>.from(prev.relations);
  final entryEntityIds = <String>[];
  final entryRelationIds = <String>[];
  final nameToId = <String, String>{};
  // Every relation id this merge created, re-asserted, OR superseded — the
  // full set commit_notebook needs to upsert. entryRelationIds alone would
  // miss a relation touched only via patch.supersedes.
  final touchedRelationIds = <String>{};

  for (final e in patch.entities) {
    if (e.name.isEmpty) continue;
    final id = slugify(e.name);
    nameToId[e.name.toLowerCase()] = id;
    final existing = entities[id];
    if (existing != null) {
      entities[id] = existing.copyWith(
        description: e.description?.isNotEmpty == true
            ? e.description
            : existing.description,
        metadata: {...existing.metadata, ...(e.metadata ?? {})},
        mentions: existing.mentions + 1,
        lastSeen: now,
        type: existing.type == EntityType.other ? e.type : existing.type,
        questions: _mergeQuestions(existing.questions, e.questions),
      );
    } else {
      entities[id] = Entity(
        id: id,
        name: e.name,
        type: e.type,
        description: e.description,
        metadata: e.metadata ?? {},
        mentions: 1,
        firstSeen: now,
        lastSeen: now,
        questions: _mergeQuestions(null, e.questions),
      );
    }
    entryEntityIds.add(id);
  }

  final explicitIds = nameToId.values.toSet();

  for (final r in patch.relations) {
    final src = nameToId[r.source.toLowerCase()] ?? slugify(r.source);
    final tgt = nameToId[r.target.toLowerCase()] ?? slugify(r.target);
    if (src.isEmpty || tgt.isEmpty || src == tgt) continue;
    final rid = '${src}__${r.label}__$tgt';

    final existing = relations[rid];
    if (existing == null) {
      relations[rid] = Relation(
        id: rid,
        source: src,
        target: tgt,
        label: r.label,
        metadata: r.metadata ?? {},
        createdAt: now,
      );
    } else {
      relations[rid] = Relation(
        id: rid,
        source: existing.source,
        target: existing.target,
        label: existing.label,
        metadata: {...existing.metadata, ...(r.metadata ?? {})},
        createdAt: existing.createdAt,
      );
    }
    entryRelationIds.add(rid);
    touchedRelationIds.add(rid);

    for (final id in [src, tgt]) {
      if (explicitIds.contains(id) || !entities.containsKey(id)) continue;
      final e = entities[id]!;
      entities[id] = e.copyWith(mentions: e.mentions + 1, lastSeen: now);
      if (!entryEntityIds.contains(id)) entryEntityIds.add(id);
    }
  }

  for (final id in patch.supersedes) {
    final r = relations[id];
    if (r == null || r.supersededAt != null) continue;
    relations[id] = Relation(
      id: r.id,
      source: r.source,
      target: r.target,
      label: r.label,
      metadata: r.metadata,
      createdAt: r.createdAt,
      supersededAt: now,
    );
    touchedRelationIds.add(id);
  }

  final entryId = 'e-${now.millisecondsSinceEpoch}';
  final uniqueEntryEntityIds = entryEntityIds.toSet().toList();
  final uniqueEntryRelationIds = entryRelationIds.toSet().toList();
  final entry = JournalEntry(
    id: entryId,
    text: text,
    createdAt: now,
    entityIds: uniqueEntryEntityIds,
    relationIds: uniqueEntryRelationIds,
  );

  // The domain change commit_notebook needs: full current values for every
  // entity/relation this merge touched (upserts are "changed rows, in
  // full," not field-level diffs — the server doesn't recompute mention
  // counts or question de-duplication, it trusts what this merge already
  // worked out). GraphPatch carries no followUp/askedQuestion today, so
  // those stay null — nothing in the Flutter app creates them yet.
  final change = ApplyTurnChange(
    entryText: text,
    entryEntityIds: uniqueEntryEntityIds,
    entryRelationIds: uniqueEntryRelationIds,
    entities: uniqueEntryEntityIds.map((id) => entities[id]!).toList(),
    relations: touchedRelationIds.map((id) => relations[id]!).toList(),
  );

  return (
    next: prev.copyWith(
      entries: [entry, ...prev.entries],
      entities: entities,
      relations: relations,
    ),
    entryId: entryId,
    change: change,
  );
}

import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBindingObserver;

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';

/// [from] with entity [id] hidden: the entity, every relation touching it,
/// and their ids in the entries (LM-29 "Remove from memory").
JournalState withoutEntity(JournalState from, String id) {
  final dropped = {
    for (final r in from.relations.values)
      if (r.source == id || r.target == id) r.id,
  };
  return from.copyWith(
    entities: {...from.entities}..remove(id),
    relations: {...from.relations}
      ..removeWhere((key, _) => dropped.contains(key)),
    entries: [
      for (final e in from.entries)
        e.entityIds.contains(id) || e.relationIds.any(dropped.contains)
            ? JournalEntry(
                id: e.id,
                text: e.text,
                createdAt: e.createdAt,
                entityIds: [
                  for (final x in e.entityIds)
                    if (x != id) x,
                ],
                relationIds: [
                  for (final x in e.relationIds)
                    if (!dropped.contains(x)) x,
                ],
              )
            : e,
    ],
  );
}

/// What a removal hid, kept so Undo can put exactly that back.
class HiddenEntity {
  HiddenEntity.capture(JournalState before, this.id)
      : entity = before.entities[id],
        relations = {
          for (final r in before.relations.values)
            if (r.source == id || r.target == id) r.id: r,
        },
        entries = {
          for (final e in before.entries)
            if (e.entityIds.contains(id)) e.id: e,
        };

  final String id;
  final Entity? entity;
  final Map<String, Relation> relations;
  final Map<String, JournalEntry> entries;

  /// [current] with this entity shown again. Only its own ids come back:
  /// another removal may still be pending and must stay hidden. A relation
  /// whose other end is still hidden is handed to that end's [HiddenEntity]
  /// (via [stillHidden]), so it returns if that removal is undone too.
  JournalState restoreInto(
    JournalState current,
    HiddenEntity? Function(String id) stillHidden,
  ) {
    final entity = this.entity;
    if (entity == null) return current;
    final restored = <String, Relation>{};
    for (final r in relations.values) {
      final other = r.source == id ? r.target : r.source;
      if (current.entities.containsKey(other)) {
        restored[r.id] = r;
      } else {
        stillHidden(other)?.relations[r.id] = r;
      }
    }
    return current.copyWith(
      entities: {...current.entities, id: entity},
      relations: {...current.relations, ...restored},
      entries: [
        for (final e in current.entries)
          if (entries[e.id] case final original?)
            JournalEntry(
              id: e.id,
              text: e.text,
              createdAt: e.createdAt,
              entityIds: [
                for (final x in original.entityIds)
                  if (x == id || e.entityIds.contains(x)) x,
              ],
              relationIds: [
                for (final x in original.relationIds)
                  if (restored.containsKey(x) || e.relationIds.contains(x)) x,
              ],
            )
          else
            e,
      ],
    );
  }
}

/// Calls [onBackground] as soon as the app leaves the foreground, so a
/// removal's undo window never outlives the process.
class BackgroundFlush with WidgetsBindingObserver {
  BackgroundFlush(this.onBackground);

  final void Function() onBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        onBackground();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/entity.dart';
import '../../models/journal_state.dart';
import '../../providers/journal_provider.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// The graph sidepane: a paper drawer listing every entity grouped into
/// sections by type. Tapping a row reports the entity via [onEntityTap] — the
/// screen closes the drawer and opens the entity note sheet. Read-only over
/// [journalProvider]; navigation is the parent's responsibility, so this widget
/// stays decoupled from the Navigator.
class GraphDrawer extends ConsumerWidget {
  final void Function(String entityId) onEntityTap;

  const GraphDrawer({super.key, required this.onEntityTap});

  // Display order + heading for each section. Only non-empty sections render.
  static const List<(EntityType, String)> _sections = [
    (EntityType.person, 'People'),
    (EntityType.place, 'Places'),
    (EntityType.project, 'Projects'),
    (EntityType.event, 'Events'),
    (EntityType.organization, 'Organizations'),
    (EntityType.activity, 'Activities'),
    (EntityType.concept, 'Concepts'),
    (EntityType.emotion, 'Emotions'),
    (EntityType.other, 'Other'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(journalProvider);
    final colors = context.lumenColors;
    final count = state.entities.length;

    return Drawer(
      backgroundColor: colors.paper,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Row(
                children: [
                  Text('Graph',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const Spacer(),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 13,
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: count == 0
                  ? _empty(colors)
                  : _list(state, colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(LumenColors colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          "No entities yet.\nStart talking and they'll appear here.",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }

  Widget _list(JournalState state, LumenColors colors) {
    final byType = <EntityType, List<Entity>>{};
    for (final entity in state.entities.values) {
      byType.putIfAbsent(entity.type, () => <Entity>[]).add(entity);
    }

    final children = <Widget>[];
    for (final (type, label) in _sections) {
      final group = byType[type];
      if (group == null || group.isEmpty) continue;
      group.sort((a, b) {
        final byMentions = b.mentions.compareTo(a.mentions);
        return byMentions != 0
            ? byMentions
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      children.add(_sectionLabel(label, colors));
      children.addAll(group.map((entity) => _entityRow(entity, colors)));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
  }

  Widget _sectionLabel(String label, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: LumenText.eyebrow(colors.mutedForeground),
      ),
    );
  }

  Widget _entityRow(Entity entity, LumenColors colors) {
    final dotColor = LumenColors.entityColors[entity.type] ??
        LumenColors.entityColors[EntityType.other]!;
    final unit = entity.mentions == 1 ? 'mention' : 'mentions';

    return InkWell(
      onTap: () => onEntityTap(entity.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration:
                  BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                entity.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 15,
                  color: colors.ink,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${entity.mentions} $unit',
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 12,
                color: colors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

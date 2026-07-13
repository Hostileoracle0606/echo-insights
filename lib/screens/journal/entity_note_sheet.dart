import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumen/logic/relative_time.dart';
import 'package:lumen/logic/snippet.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/wikilink.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';

Future<void> showEntityNoteSheet(BuildContext context, String entityId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => EntityNoteSheet(entityId: entityId),
  );
}

class EntityNoteSheet extends ConsumerStatefulWidget {
  final String entityId;

  const EntityNoteSheet({super.key, required this.entityId});

  @override
  ConsumerState<EntityNoteSheet> createState() => _EntityNoteSheetState();
}

class _EntityNoteSheetState extends ConsumerState<EntityNoteSheet> {
  late final List<String> _history = [widget.entityId];

  String get _currentId => _history.last;
  bool get _canGoBack => _history.length > 1;

  void _back() {
    if (!_canGoBack) return;
    setState(_history.removeLast);
  }

  void _open(String id) {
    if (id == _currentId) return;
    setState(() => _history.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(journalProvider);
    final colors = context.lumenColors;
    final entity = state.entities[_currentId];

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(16),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 30,
                color: Colors.black.withValues(alpha: 0.18),
                offset: const Offset(0, -12),
              ),
            ],
          ),
          child: entity == null
              ? _unavailable(scrollController, colors)
              : _note(scrollController, state, entity, colors),
        );
      },
    );
  }

  Widget _header(LumenColors colors) {
    return Row(
      children: [
        if (_canGoBack)
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: colors.mutedForeground,
            tooltip: 'Back',
            onPressed: _back,
          )
        else
          const SizedBox(width: 48, height: 48),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close),
          color: colors.mutedForeground,
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _unavailable(ScrollController controller, LumenColors colors) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _header(colors),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'Note unavailable',
            style: TextStyle(color: colors.mutedForeground),
          ),
        ),
      ],
    );
  }

  Widget _note(
    ScrollController controller,
    JournalState state,
    Entity entity,
    LumenColors colors,
  ) {
    final outbound = state.relations.values
        .where(
          (relation) =>
              relation.isActive &&
              relation.source == entity.id &&
              state.entities[relation.target] != null,
        )
        .toList();
    final inbound = state.relations.values
        .where(
          (relation) =>
              relation.isActive &&
              relation.target == entity.id &&
              relation.source != entity.id &&
              state.entities[relation.source] != null,
        )
        .toList();
    final recent = state.entries
        .where((entry) => entry.entityIds.contains(entity.id))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final dotColor = LumenColors.entityColors[entity.type] ??
        LumenColors.entityColors[EntityType.other]!;

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _header(colors),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              entity.type.name.toUpperCase(),
              style: LumenText.eyebrow(colors.mutedForeground),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          entity.name,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          _metaLine(entity),
          style: TextStyle(fontSize: 12, color: colors.mutedForeground),
        ),
        if (entity.description?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 14),
          Text(
            entity.description!,
            style: TextStyle(fontSize: 15, height: 1.5, color: colors.ink),
          ),
        ],
        if (outbound.isNotEmpty) ...[
          _sectionLabel('Connections', colors),
          for (final relation in outbound)
            _connectionRow(state, relation, colors, outbound: true),
        ],
        if (inbound.isNotEmpty) ...[
          _sectionLabel('Mentioned by', colors),
          for (final relation in inbound)
            _connectionRow(state, relation, colors, outbound: false),
        ],
        if (recent.isNotEmpty) ...[
          _sectionLabel('Recent mentions', colors),
          for (final entry in recent.take(12)) _mentionRow(entry, colors),
        ],
      ],
    );
  }

  String _metaLine(Entity entity) {
    final label = entity.mentions == 1 ? 'mention' : 'mentions';
    return '${entity.mentions} $label · last ${relativeTime(entity.lastSeen)}';
  }

  Widget _sectionLabel(String text, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: LumenText.eyebrow(colors.mutedForeground),
      ),
    );
  }

  Widget _connectionRow(
    JournalState state,
    Relation relation,
    LumenColors colors, {
    required bool outbound,
  }) {
    final label = relation.label.replaceAll('_', ' ');
    final relatedId = outbound ? relation.target : relation.source;
    final related = state.entities[relatedId]!;
    final isSelf = relation.source == relation.target;
    final link = WikiLink(
      entityId: related.id,
      label: related.name,
      onTap: isSelf ? null : () => _open(related.id),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: outbound
            ? [
                Text(
                  '$label → ',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.mutedForeground,
                  ),
                ),
                link,
              ]
            : [
                link,
                Text(
                  ' — $label',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.mutedForeground,
                  ),
                ),
              ],
      ),
    );
  }

  Widget _mentionRow(JournalEntry entry, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            relativeTime(entry.createdAt),
            style: TextStyle(fontSize: 12, color: colors.mutedForeground),
          ),
          const SizedBox(height: 3),
          Text(
            snippet(entry.text),
            style: TextStyle(fontSize: 13, height: 1.4, color: colors.ink),
          ),
        ],
      ),
    );
  }
}

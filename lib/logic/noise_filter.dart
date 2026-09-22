import '../models/graph_patch.dart';

const _defaultNoise = {
  'i',
  'me',
  'my',
  'mine',
  'you',
  'your',
  'yours',
  'we',
  'us',
  'our',
  'they',
  'them',
  'their',
  'today',
  'yesterday',
  'tomorrow',
  'morning',
  'afternoon',
  'evening',
  'night',
  'now',
  'later',
};

String normalizeName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]+'), '').trim();

GraphPatch filterNoise(GraphPatch patch, {Set<String>? extra}) {
  final stop = {..._defaultNoise, ...(extra ?? {})};

  final kept = patch.entities.where((entity) {
    final key = normalizeName(entity.name);
    return key.isNotEmpty && key.length >= 2 && !stop.contains(key);
  }).toList();

  final keptKeys = kept.map((entity) => normalizeName(entity.name)).toSet();
  final droppedKeys = patch.entities
      .map((entity) => normalizeName(entity.name))
      .where((key) => !keptKeys.contains(key))
      .toSet();

  final relations = patch.relations
      .where(
        (relation) =>
            !droppedKeys.contains(normalizeName(relation.source)) &&
            !droppedKeys.contains(normalizeName(relation.target)),
      )
      .toList();

  return GraphPatch(
    entities: kept,
    relations: relations,
    supersedes: patch.supersedes,
  );
}

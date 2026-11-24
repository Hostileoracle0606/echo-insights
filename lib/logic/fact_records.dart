import '../models/graph_patch.dart';
import 'slugify.dart';

/// EC-03: the rows record_memory_facts receives for one committed turn.
/// Entities are keyed by the slug merge() gives them, so a fact lands on the
/// entity its turn created or touched. A removed or forgotten entity
/// ([suppressed]) gets none.
List<Map<String, dynamic>> factRecords(
  GraphPatch patch, {
  Set<String> suppressed = const {},
}) =>
    [
      for (final fact in patch.facts)
        if (slugify(fact.entity) case final id
            when id.isNotEmpty && !suppressed.contains(id))
          {
            'entityId': id,
            ...(fact.toJson()..remove('entity')),
          },
    ];

/// [time] as ISO 8601 with its UTC offset ("2026-11-22T17:23:00-05:00"), so
/// the extraction model resolves "yesterday" on the user's own calendar.
String isoWithOffset(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)}'
      'T${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
      '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

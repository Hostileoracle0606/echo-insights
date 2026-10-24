import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/notebook.dart';
import '../models/relation.dart';

/// Obsidian-vault Markdown export, ported one for one from the web exporter
/// (src/lib/obsidian-export.ts) so a vault can mix files from both:
///
///   Lumen Vault/
///     README.md            ← map of content: recent days + entities by type
///     Maya.md              ← one note per entity, at the root
///     Daily/2026-04-26.md  ← one note per local day, a section per utterance
///
/// test/markdown_export_test.dart holds this to the web exporter's own output
/// (scripts/markdown-export-fixtures.ts). Two deliberate differences, both in
/// cases where the web export loses a note: names that collide after cleaning
/// get a " (2)" suffix instead of overwriting each other, and an entity called
/// "README" no longer replaces the index.

/// An exported vault: zip path → file contents, in zip order.
class MarkdownVault {
  final Map<String, String> files;
  const MarkdownVault(this.files);
}

const _root = 'Lumen Vault';

const _typeOrder = <(EntityType, String)>[
  (EntityType.person, 'People'),
  (EntityType.place, 'Places'),
  (EntityType.organization, 'Organizations'),
  (EntityType.project, 'Projects'),
  (EntityType.event, 'Events'),
  (EntityType.activity, 'Activities'),
  (EntityType.concept, 'Concepts'),
  (EntityType.emotion, 'Feelings'),
  (EntityType.other, 'Other'),
];

/// Builds the vault for one notebook's [state]. Pure: no I/O.
///
/// [now] stamps the README; [toLocal] picks the time zone that day files and
/// time anchors are cut in (the device's, by default). Tests pin both.
MarkdownVault buildVault(
  JournalState state, {
  DateTime? now,
  DateTime Function(DateTime)? toLocal,
}) {
  final local = toLocal ?? (DateTime d) => d.toLocal();
  final byId = state.entities;
  final links = _NoteNames(byId.values);
  final files = <String, String>{};

  final active = state.relations.values.where((r) => r.supersededAt == null);
  final outgoing = <String, List<Relation>>{};
  final incoming = <String, List<Relation>>{};
  for (final r in active) {
    outgoing.putIfAbsent(r.source, () => []).add(r);
    incoming.putIfAbsent(r.target, () => []).add(r);
  }

  // Group entries by local day; days keep the store's newest-first order,
  // entries inside a day read oldest first.
  final byDay = <String, List<JournalEntry>>{};
  for (final entry in state.entries) {
    byDay.putIfAbsent(_dayKey(local(entry.createdAt)), () => []).add(entry);
  }
  for (final key in byDay.keys.toList()) {
    byDay[key] = _stableSorted(
      byDay[key]!,
      (a, b) => a.createdAt.compareTo(b.createdAt),
    );
  }

  // Recent mentions keep the store's newest-first order.
  final mentionsByEntity = <String, List<JournalEntry>>{};
  for (final entry in state.entries) {
    for (final id in entry.entityIds) {
      mentionsByEntity.putIfAbsent(id, () => []).add(entry);
    }
  }

  for (final e in byId.values) {
    files['$_root/${links.fileStem(e.id)}.md'] = _entityNote(
      e,
      outgoing[e.id] ?? const [],
      incoming[e.id] ?? const [],
      mentionsByEntity[e.id] ?? const [],
      byId,
      links,
      local,
    );
  }

  for (final MapEntry(key: date, value: entries) in byDay.entries) {
    files['$_root/Daily/$date.md'] =
        _dailyNote(date, entries, byId, links, local);
  }

  files['$_root/README.md'] = _readme(
    state,
    byDay,
    links,
    local(now ?? DateTime.now()),
  );

  return MarkdownVault(files);
}

String _entityNote(
  Entity e,
  List<Relation> outgoing,
  List<Relation> incoming,
  List<JournalEntry> recentMentions,
  Map<String, Entity> byId,
  _NoteNames links,
  DateTime Function(DateTime) local,
) {
  final fm = _frontmatter([
    ('id', e.id),
    ('type', e.type.name),
    ('mentions', e.mentions),
    ('firstSeen', _isoString(e.firstSeen)),
    ('lastSeen', _isoString(e.lastSeen)),
    ('metadata', e.metadata),
    ('aliases', const <String>[]),
  ]);

  final sections = <String>[fm, '', '# ${e.name}', ''];
  final description = e.description;
  if (description != null && description.isNotEmpty) {
    sections.addAll([description, '']);
  }

  final questions = e.questions;
  if (questions != null && questions.isNotEmpty) {
    sections.add('## Questions to explore');
    sections.addAll(questions.map((q) => '- [ ] $q'));
    sections.add('');
  }

  if (outgoing.isNotEmpty) {
    sections.add('## Connections');
    for (final r in outgoing) {
      if (byId.containsKey(r.target)) {
        sections.add('- **${_label(r)}** → ${links.link(r.target)}');
      }
    }
    sections.add('');
  }
  if (incoming.isNotEmpty) {
    sections.add('## Mentioned by');
    for (final r in incoming) {
      if (byId.containsKey(r.source)) {
        sections.add('- ${links.link(r.source)} — ${_label(r)}');
      }
    }
    sections.add('');
  }

  // Anchored links into the day notes, capped at the five most recent.
  if (recentMentions.isNotEmpty) {
    sections.add('## Recent mentions');
    for (final entry in recentMentions.take(5)) {
      final at = local(entry.createdAt);
      final date = _dayKey(at);
      final time = _timeAnchor(at);
      sections.add(
        '- [[Daily/$date#$time|$date $time]] — ${_snippet(entry.text)}',
      );
    }
    sections.add('');
  }

  return sections.join('\n');
}

String _dailyNote(
  String dateKey,
  List<JournalEntry> entries,
  Map<String, Entity> byId,
  _NoteNames links,
  DateTime Function(DateTime) local,
) {
  final names = <String>{
    for (final entry in entries)
      for (final id in entry.entityIds)
        if (byId[id]?.name case final name? when name.isNotEmpty) name,
  };

  final fm = _frontmatter([
    ('date', dateKey),
    ('entryCount', entries.length),
    ('entities', names.toList()),
  ]);

  final sections = <String>[fm, '', '# ${_longDate(dateKey)}', ''];

  for (final entry in entries) {
    // A bare time heading keeps anchors clean: [[2026-04-26#14:32]].
    sections.addAll(['## ${_timeAnchor(local(entry.createdAt))}', '']);
    final linked = [
      for (final id in entry.entityIds)
        if (byId[id]?.name.isNotEmpty ?? false) links.link(id),
    ].join(' · ');
    if (linked.isNotEmpty) sections.addAll([linked, '']);
    sections.addAll([entry.text, '']);
  }
  return sections.join('\n');
}

String _readme(
  JournalState state,
  Map<String, List<JournalEntry>> byDay,
  _NoteNames links,
  DateTime now,
) {
  final lines = <String>[
    '# Lumen Vault',
    '',
    'Exported ${_localeString(now)} — ${state.entities.length} entities, '
        '${state.relations.length} relations, ${state.entries.length} entries '
        'across ${byDay.length} day(s).',
    '',
  ];

  final recentDays = (byDay.keys.toList()..sort((a, b) => b.compareTo(a)))
      .take(14)
      .toList();
  if (recentDays.isNotEmpty) {
    lines.addAll(['## Recent days', '']);
    for (final date in recentDays) {
      final count = byDay[date]!.length;
      lines.add(
        '- [[Daily/$date|$date]] _($count ${count == 1 ? 'entry' : 'entries'})_',
      );
    }
    lines.add('');
  }

  final byType = <EntityType, List<Entity>>{};
  for (final e in state.entities.values) {
    byType.putIfAbsent(e.type, () => []).add(e);
  }
  for (final (type, label) in _typeOrder) {
    final list = _stableSorted(
      byType[type] ?? const <Entity>[],
      (a, b) => b.mentions.compareTo(a.mentions),
    );
    if (list.isEmpty) continue;
    lines.addAll(['## $label', '']);
    for (final e in list) {
      final unit = e.mentions == 1 ? 'mention' : 'mentions';
      lines.add('- ${links.link(e.id)} _(${e.mentions} $unit)_');
    }
    lines.add('');
  }

  return lines.join('\n');
}

/// Note filenames and the wikilinks that reach them.
///
/// Links use the entity's own name, as on the web, unless the note had to be
/// renamed to avoid a collision; then they point at the file and keep the
/// name as the alias: `[[Maya (2)|Maya]]`.
class _NoteNames {
  final Map<String, String> _stems = {};
  final Map<String, String> _names = {};
  final Set<String> _renamed = {};

  _NoteNames(Iterable<Entity> entities) {
    // Lower-cased: iOS and macOS file systems ignore case, so "Maya.md" and
    // "maya.md" would land on one file once unzipped.
    final taken = <String>{'readme'};
    for (final e in entities) {
      final base = _safeFilename(e.name).isEmpty
          ? 'Untitled'
          : _safeFilename(e.name);
      var stem = base;
      for (var n = 2; taken.contains(stem.toLowerCase()); n++) {
        stem = '$base ($n)';
      }
      taken.add(stem.toLowerCase());
      _stems[e.id] = stem;
      _names[e.id] = e.name;
      if (stem != base) _renamed.add(e.id);
    }
  }

  String fileStem(String id) => _stems[id]!;

  String link(String id) => _renamed.contains(id)
      ? '[[${_stems[id]}|${_names[id]}]]'
      : '[[${_names[id]}]]';
}

String _safeFilename(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-').trim();

String _label(Relation r) => r.label.replaceAll('_', ' ');

/// YAML frontmatter, mirroring the web helper: empty values are skipped,
/// lists become `- item`s, maps become indented `key: value`s.
String _frontmatter(List<(String, Object?)> fields) {
  final lines = ['---'];
  String flat(Object? v) => _jsString(v).replaceAll('\n', ' ');
  for (final (key, value) in fields) {
    switch (value) {
      case null:
        continue;
      case String() when value.isEmpty:
        continue;
      case List() when value.isEmpty:
        continue;
      case List():
        lines.add('$key:');
        lines.addAll(value.map((x) => '  - ${flat(x)}'));
      case Map():
        lines.add('$key:');
        for (final MapEntry(:key, :value) in value.entries) {
          lines.add('  $key: ${flat(value)}');
        }
      default:
        lines.add('$key: ${flat(value)}');
    }
  }
  lines.add('---');
  return lines.join('\n');
}

/// JavaScript's `String(v)` for the JSON values metadata can hold.
String _jsString(Object? v) => switch (v) {
      null => 'null',
      double(isNaN: true) => 'NaN',
      double(isInfinite: true) => v > 0 ? 'Infinity' : '-Infinity',
      double() when v == v.truncateToDouble() && v.abs() < 1e21 =>
        v.toInt().toString(),
      List() => v.map((x) => x == null ? '' : _jsString(x)).join(','),
      Map() => '[object Object]',
      _ => v.toString(),
    };

String _two(int n) => n.toString().padLeft(2, '0');

/// `Date.prototype.toISOString`: UTC, milliseconds, `Z`.
String _isoString(DateTime d) {
  final u = d.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}'
      'T${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}'
      '.${u.millisecond.toString().padLeft(3, '0')}Z';
}

/// Local-day key, YYYY-MM-DD. Cut in local time, never UTC, so an evening
/// conversation west of Greenwich stays in one day file.
String _dayKey(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)}';

String _timeAnchor(DateTime local) =>
    '${_two(local.hour)}:${_two(local.minute)}';

String _snippet(String text, [int max = 140]) {
  final trimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return trimmed.length > max ? '${trimmed.substring(0, max - 1)}…' : trimmed;
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// en-US `toLocaleDateString` with weekday, month, day and year:
/// "Sunday, April 26, 2026".
String _longDate(String dateKey) {
  final [y, m, d] = dateKey.split('-').map(int.parse).toList();
  final date = DateTime.utc(y, m, d);
  return '${_weekdays[date.weekday - 1]}, ${_months[m - 1]} $d, $y';
}

/// en-US `toLocaleString`: "4/27/2026, 9:30:00 AM".
String _localeString(DateTime local) {
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final meridiem = local.hour < 12 ? 'AM' : 'PM';
  return '${local.month}/${local.day}/${local.year}, '
      '$hour:${_two(local.minute)}:${_two(local.second)} $meridiem';
}

/// [List.sort] isn't stable; the web export relies on `Array.sort`, which is.
List<T> _stableSorted<T>(List<T> list, int Function(T, T) compare) {
  final indexed = list.indexed.toList()
    ..sort((a, b) {
      final c = compare(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return [for (final (_, item) in indexed) item];
}

// ─── All of memory ──────────────────────────────────────────────────────────

/// Merges several notebooks' states into one, by entity and relation id, with
/// the rules of LM-06's `user_entities` / `user_relations` views:
///
/// - entity: summed mentions, earliest first-seen, latest last-seen; name,
///   type, metadata and questions from the latest sighting; the latest
///   non-null description.
/// - relation: fields from the latest row; active when its latest unsuperseded
///   row is newer than its latest supersession.
/// - entries: all of them, newest first.
JournalState mergeJournalStates(Iterable<JournalState> states) {
  final entities = <String, Entity>{};
  final descriptionSeen = <String, DateTime>{};
  final latestDescription = <String, String>{};
  final relations = <String, Relation>{};
  final relationFirstCreated = <String, DateTime>{};
  final relationLatestActive = <String, DateTime>{};
  final relationLatestSuperseded = <String, DateTime>{};
  final entries = <JournalEntry>[];
  final followUps = [for (final s in states) ...s.followUps];

  for (final state in states) {
    entries.addAll(state.entries);

    for (final e in state.entities.values) {
      final description = e.description;
      final seen = descriptionSeen[e.id];
      if (description != null && (seen == null || e.lastSeen.isAfter(seen))) {
        descriptionSeen[e.id] = e.lastSeen;
        latestDescription[e.id] = description;
      }
      final current = entities[e.id];
      if (current == null) {
        entities[e.id] = e;
        continue;
      }
      final latest = e.lastSeen.isAfter(current.lastSeen) ? e : current;
      entities[e.id] = Entity(
        id: e.id,
        name: latest.name,
        type: latest.type,
        description: latestDescription[e.id],
        metadata: latest.metadata,
        mentions: current.mentions + e.mentions,
        firstSeen: e.firstSeen.isBefore(current.firstSeen)
            ? e.firstSeen
            : current.firstSeen,
        lastSeen: latest.lastSeen,
        questions: latest.questions,
      );
    }

    for (final r in state.relations.values) {
      DateTime later(DateTime? a, DateTime b) =>
          a == null || b.isAfter(a) ? b : a;
      final first = relationFirstCreated[r.id];
      if (first == null || r.createdAt.isBefore(first)) {
        relationFirstCreated[r.id] = r.createdAt;
      }
      final superseded = r.supersededAt;
      if (superseded == null) {
        relationLatestActive[r.id] =
            later(relationLatestActive[r.id], r.createdAt);
      } else {
        relationLatestSuperseded[r.id] =
            later(relationLatestSuperseded[r.id], superseded);
      }
      final current = relations[r.id];
      if (current == null || r.createdAt.isAfter(current.createdAt)) {
        relations[r.id] = r;
      }
    }
  }

  return JournalState(
    entries: _stableSorted(entries, (a, b) => b.createdAt.compareTo(a.createdAt)),
    entities: entities,
    relations: {
      for (final MapEntry(key: id, value: r) in relations.entries)
        id: Relation(
          id: id,
          source: r.source,
          target: r.target,
          label: r.label,
          metadata: r.metadata,
          createdAt: relationFirstCreated[id]!,
          supersededAt: _relationActive(
            relationLatestActive[id],
            relationLatestSuperseded[id],
          )
              ? null
              : relationLatestSuperseded[id],
        ),
    },
    followUps: followUps,
  );
}

bool _relationActive(DateTime? latestActive, DateTime? latestSuperseded) =>
    latestActive != null &&
    (latestSuperseded == null || latestActive.isAfter(latestSuperseded));

bool _all(Notebook _) => true;

/// Builds one vault from every notebook the user has.
class AllMemoryExport {
  final Future<List<Notebook>> Function() listNotebooks;

  /// A notebook's state, or null when it is gone or not the caller's.
  final Future<JournalState?> Function(String notebookId) loadNotebookState;

  const AllMemoryExport({
    required this.listNotebooks,
    required this.loadNotebookState,
  });

  /// Loads each notebook [include] accepts, merges them and builds the vault
  /// off the UI isolate. [onProgress] reports notebooks loaded so far.
  ///
  /// [include] is the privacy filter's hook (LM-20); today nothing is left out.
  Future<MarkdownVault> buildAllMemoryVault({
    bool Function(Notebook) include = _all,
    void Function(int done, int total)? onProgress,
    DateTime? now,
  }) async {
    final notebooks = (await listNotebooks()).where(include).toList();
    onProgress?.call(0, notebooks.length);
    final states = <JournalState>[];
    for (final (i, notebook) in notebooks.indexed) {
      final state = await loadNotebookState(notebook.id);
      if (state != null) states.add(state);
      onProgress?.call(i + 1, notebooks.length);
    }
    return _buildInBackground(mergeJournalStates(states), now ?? DateTime.now());
  }
}

// Top-level so the isolate closure captures only its arguments.
Future<MarkdownVault> _buildInBackground(JournalState state, DateTime now) =>
    Isolate.run(() => buildVault(state, now: now));

// ─── Zip and share ──────────────────────────────────────────────────────────

/// `Lumen Vault-2026-10-23.zip`, dated in local time.
String vaultZipName(DateTime now) => 'Lumen Vault-${_dayKey(now)}.zip';

/// The vault as zip bytes. Paths are stored as UTF-8 with the zip's UTF-8
/// flag set, so "Phillip Street Café.md" unzips intact.
Uint8List encodeVaultZip(MarkdownVault vault) {
  final archive = Archive();
  for (final MapEntry(key: path, value: contents) in vault.files.entries) {
    archive.addFile(ArchiveFile.bytes(path, utf8.encode(contents)));
  }
  return Uint8List.fromList(
    ZipEncoder(filenameEncoding: utf8).encode(archive),
  );
}

/// Writes the vault to [name] in [directory] (the app's temporary directory
/// by default), encoding off the UI isolate.
Future<File> writeVaultZip(
  MarkdownVault vault,
  String name, {
  Directory? directory,
}) async {
  final dir = directory ?? await getTemporaryDirectory();
  final bytes = await _encodeInBackground(vault);
  return File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
}

Future<Uint8List> _encodeInBackground(MarkdownVault vault) =>
    Isolate.run(() => encodeVaultZip(vault));

/// Hands a built vault to the user. The drawer's Export action calls one of
/// these; tests inject their own so the real share sheet never opens.
typedef ShareVault = Future<void> Function(MarkdownVault vault, {Rect? origin});

/// Zips [vault] and opens the iOS share sheet on it. [origin] anchors the
/// sheet's popover on iPad.
Future<void> shareVaultZip(MarkdownVault vault, {Rect? origin}) async {
  final file = await writeVaultZip(vault, vaultZipName(DateTime.now()));
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/zip')],
      sharePositionOrigin: origin,
    ),
  );
}

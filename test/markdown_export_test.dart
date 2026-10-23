// LM-30: the iPhone Markdown export must produce the same Obsidian vault as
// the web exporter (src/lib/obsidian-export.ts). The golden files under
// test/fixtures/markdown_export/web/ are the web exporter's own output on
// state.json; regenerate them with `node scripts/markdown-export-fixtures.ts`.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/conversation_mode.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/services/notebook_commit_service.dart';

const _fixtureDir = 'test/fixtures/markdown_export';

// The script pins the web exporter's clock, time zone (UTC) and locale.
final _fixedNow = DateTime.utc(2026, 4, 27, 9, 30);
DateTime _utc(DateTime d) => d.toUtc();

JournalState _fixtureState() {
  final json = jsonDecode(File('$_fixtureDir/state.json').readAsStringSync())
      as Map<String, dynamic>;
  return NotebookSnapshot.fromJson({
    'notebookId': 'fixture',
    'revision': 0,
    'state': json,
  }).state;
}

Entity _entity(
  String id,
  String name, {
  EntityType type = EntityType.person,
  String? description,
  int mentions = 1,
  DateTime? firstSeen,
  DateTime? lastSeen,
}) =>
    Entity(
      id: id,
      name: name,
      type: type,
      description: description,
      metadata: const {},
      mentions: mentions,
      firstSeen: firstSeen ?? DateTime.utc(2026, 4, 25),
      lastSeen: lastSeen ?? DateTime.utc(2026, 4, 25),
    );

Relation _relation(
  String id,
  String source,
  String target, {
  required DateTime createdAt,
  DateTime? supersededAt,
  String label = 'knows',
}) =>
    Relation(
      id: id,
      source: source,
      target: target,
      label: label,
      metadata: const {},
      createdAt: createdAt,
      supersededAt: supersededAt,
    );

JournalEntry _entry(String id, DateTime at, List<String> entityIds) =>
    JournalEntry(
      id: id,
      text: 'Entry $id',
      createdAt: at,
      entityIds: entityIds,
      relationIds: const [],
    );

JournalState _state({
  List<JournalEntry> entries = const [],
  List<Entity> entities = const [],
  List<Relation> relations = const [],
}) =>
    JournalState(
      entries: entries,
      entities: {for (final e in entities) e.id: e},
      relations: {for (final r in relations) r.id: r},
      followUps: const [],
    );

Notebook _notebook(String id, ConversationMode mode) => Notebook(
      id: id,
      userId: 'user',
      title: id,
      titleSource: 'auto',
      startedAt: DateTime.utc(2026, 4, 25),
      entityCount: 1,
      createdAt: DateTime.utc(2026, 4, 25),
      updatedAt: DateTime.utc(2026, 4, 25),
      conversationMode: mode,
    );

void main() {
  group('buildVault matches the web exporter', () {
    final vault = buildVault(_fixtureState(), now: _fixedNow, toLocal: _utc);
    final webPaths = (jsonDecode(
      File('$_fixtureDir/web-paths.json').readAsStringSync(),
    ) as List<dynamic>)
        .cast<String>();

    test('same files in the same order', () {
      expect(vault.files.keys.toList(), webPaths);
    });

    for (final path in webPaths) {
      test(path, () {
        final golden = File('$_fixtureDir/web/$path').readAsStringSync();
        expect(vault.files[path], golden);
      });
    }
  });

  group('filenames', () {
    test('names that collide after cleaning get a numbered suffix', () {
      final vault = buildVault(
        _state(entities: [
          _entity('a', 'A/B'),
          _entity('b', 'A:B'),
          _entity('c', 'a*b'),
        ]),
        now: _fixedNow,
        toLocal: _utc,
      );
      expect(
        vault.files.keys.where((p) => !p.endsWith('README.md')),
        ['Lumen Vault/A-B.md', 'Lumen Vault/A-B (2).md', 'Lumen Vault/a-b (3).md'],
      );
    });

    test('links to a suffixed note point at its file, aliased to the name', () {
      final vault = buildVault(
        _state(
          entities: [_entity('a', 'Maya'), _entity('b', 'maya')],
          relations: [
            _relation('r', 'a', 'b', createdAt: DateTime.utc(2026, 4, 25)),
          ],
        ),
        now: _fixedNow,
        toLocal: _utc,
      );
      expect(vault.files['Lumen Vault/Maya.md'],
          contains('- **knows** → [[maya (2)|maya]]'));
      expect(vault.files['Lumen Vault/README.md'],
          contains('- [[maya (2)|maya]] _(1 mention)_'));
    });

    test('an entity called README never overwrites the index', () {
      final vault = buildVault(
        _state(entities: [_entity('r', 'README')]),
        now: _fixedNow,
        toLocal: _utc,
      );
      expect(vault.files['Lumen Vault/README (2).md'], contains('# README'));
      expect(vault.files['Lumen Vault/README.md'], startsWith('# Lumen Vault'));
    });
  });

  group('zip', () {
    final vault = buildVault(_fixtureState(), now: _fixedNow, toLocal: _utc);
    const accented = 'Lumen Vault/Phillip Street Café.md';

    test('stores paths as flagged UTF-8 and round-trips them', () {
      final bytes = encodeVaultZip(vault);

      // Every local file header (PK\x03\x04) sets general-purpose bit 11,
      // the "names are UTF-8" flag, so unzippers don't garble "Café".
      var headers = 0;
      for (var i = 0; i + 8 < bytes.length; i++) {
        if (bytes[i] == 0x50 &&
            bytes[i + 1] == 0x4b &&
            bytes[i + 2] == 0x03 &&
            bytes[i + 3] == 0x04) {
          headers++;
          final flags = bytes[i + 6] | (bytes[i + 7] << 8);
          expect(flags & 0x800, 0x800, reason: 'UTF-8 flag on entry $headers');
        }
      }
      expect(headers, vault.files.length);

      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.where((f) => f.isFile).map((f) => f.name);
      expect(names, vault.files.keys);
      final cafe = archive.findFile(accented)!;
      expect(utf8.decode(cafe.content as List<int>), vault.files[accented]);
    });

    test('writeVaultZip writes the named file', () async {
      final dir = await Directory.systemTemp.createTemp('lm30');
      addTearDown(() => dir.delete(recursive: true));
      final file = await writeVaultZip(
        vault,
        vaultZipName(DateTime(2026, 10, 23)),
        directory: dir,
      );
      expect(file.path, '${dir.path}/Lumen Vault-2026-10-23.zip');
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      expect(archive.findFile(accented), isNotNull);
    });
  });

  group('mergeJournalStates', () {
    final early = DateTime.utc(2026, 4, 1);
    final mid = DateTime.utc(2026, 4, 10);
    final late = DateTime.utc(2026, 4, 20);

    test('merges entities the way user_entities does', () {
      final merged = mergeJournalStates([
        _state(entities: [
          _entity('maya', 'Maya',
              description: 'old', mentions: 2, firstSeen: mid, lastSeen: mid),
        ]),
        _state(entities: [
          _entity('maya', 'Maya R.',
              mentions: 3, firstSeen: early, lastSeen: late),
        ]),
        _state(entities: [
          _entity('maya', 'Maya',
              description: 'newer', mentions: 1, firstSeen: mid, lastSeen: mid),
        ]),
      ]);
      final maya = merged.entities['maya']!;
      expect(maya.mentions, 6);
      expect(maya.firstSeen, early);
      expect(maya.lastSeen, late);
      // Name follows the latest sighting; description the latest non-null.
      expect(maya.name, 'Maya R.');
      expect(maya.description, anyOf('old', 'newer'));
    });

    test('description is the latest non-null one', () {
      final merged = mergeJournalStates([
        _state(entities: [
          _entity('a', 'A', description: 'first', lastSeen: early),
        ]),
        _state(entities: [
          _entity('a', 'A', description: 'second', lastSeen: mid),
        ]),
        _state(entities: [_entity('a', 'A', lastSeen: late)]),
      ]);
      expect(merged.entities['a']!.description, 'second');
    });

    test('a later contradiction supersedes; a later restatement revives', () {
      final contradicted = mergeJournalStates([
        _state(relations: [_relation('r', 'a', 'b', createdAt: early)]),
        _state(relations: [
          _relation('r', 'a', 'b', createdAt: early, supersededAt: mid),
        ]),
      ]);
      expect(contradicted.relations['r']!.supersededAt, mid);

      final revived = mergeJournalStates([
        _state(relations: [
          _relation('r', 'a', 'b', createdAt: early, supersededAt: mid),
        ]),
        _state(relations: [_relation('r', 'a', 'b', createdAt: late)]),
      ]);
      expect(revived.relations['r']!.supersededAt, isNull);
    });

    test('entries from every notebook, newest first', () {
      final merged = mergeJournalStates([
        _state(entries: [_entry('2', mid, const []), _entry('1', early, const [])]),
        _state(entries: [_entry('3', late, const [])]),
      ]);
      expect(merged.entries.map((e) => e.id), ['3', '2', '1']);
    });
  });

  group('AllMemoryExport', () {
    final states = {
      'talk': _state(entities: [_entity('maya', 'Maya')]),
      'prep': _state(entities: [_entity('secret', 'Interview prep')]),
    };
    AllMemoryExport exporter() => AllMemoryExport(
          listNotebooks: () async => [
            _notebook('talk', ConversationMode.justTalk),
            _notebook('prep', ConversationMode.sessionPrep),
          ],
          loadNotebookState: (id) async => states[id],
        );

    test('includes every notebook by default, reporting progress', () async {
      final progress = <(int, int)>[];
      final vault = await exporter().buildAllMemoryVault(
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(vault.files.keys, contains('Lumen Vault/Maya.md'));
      expect(vault.files.keys, contains('Lumen Vault/Interview prep.md'));
      expect(progress, [(0, 2), (1, 2), (2, 2)]);
    });

    test('the include filter leaves notebooks out', () async {
      final vault = await exporter().buildAllMemoryVault(
        include: (n) => n.conversationMode != ConversationMode.sessionPrep,
      );
      expect(vault.files.keys, contains('Lumen Vault/Maya.md'));
      expect(vault.files.keys, isNot(contains('Lumen Vault/Interview prep.md')));
    });
  });

  test('a 200-entity vault builds in under 2 seconds', () {
    final start = DateTime.utc(2026, 1, 1);
    final entities = [
      for (var i = 0; i < 200; i++)
        _entity('e$i', 'Entity $i', type: EntityType.values[i % 9]),
    ];
    final relations = [
      for (var i = 0; i < 400; i++)
        _relation('r$i', 'e${i % 200}', 'e${(i * 7) % 200}', createdAt: start),
    ];
    final entries = [
      for (var i = 999; i >= 0; i--)
        _entry('n$i', start.add(Duration(hours: i)),
            ['e${i % 200}', 'e${(i * 3) % 200}']),
    ];
    final watch = Stopwatch()..start();
    final vault = buildVault(
      _state(entities: entities, relations: relations, entries: entries),
    );
    watch.stop();
    expect(vault.files.length, greaterThan(200));
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });
}

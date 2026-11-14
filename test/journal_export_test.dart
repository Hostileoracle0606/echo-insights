// LM-52: "Export my journal". The fixture under test/fixtures/journal_export
// has the shape export_my_data() returns (pinned by
// supabase/tests/database/export_my_data_test.sql); these tests hold the Dart
// side to it: a lossless round trip, a readable Markdown file per notebook,
// and a zip with both.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_export.dart';
import 'package:lumen/services/journal_export_service.dart';
import 'package:lumen/services/markdown_export.dart';

Map<String, dynamic> _fixture() => jsonDecode(
        File('test/fixtures/journal_export/export.json').readAsStringSync())
    as Map<String, dynamic>;

DateTime _utc(DateTime d) => d.toUtc();

void main() {
  group('JournalExport model', () {
    test('round-trips the RPC shape with no data loss', () {
      final json = _fixture();
      final export = JournalExport.fromJson(json);

      expect(export.notebooks, hasLength(2));
      // Through real JSON text too, as the zip stores it.
      expect(jsonDecode(jsonEncode(export.toJson())), json);
      expect(export.toJson(), json);
    });

    test('keeps fields and keys this app does not know yet', () {
      final json = _fixture()
        ..['futureTopLevel'] = {'a': 1}
        ..['notebooks'] = [
          {
            ...(_fixture()['notebooks'] as List).first as Map<String, dynamic>,
            'futureField': 'kept',
            'futureList': [1, 2],
          },
        ];
      expect(JournalExport.fromJson(json).toJson(), json);
    });

    test('types the notebook for the renderer', () {
      final nb = JournalExport.fromJson(_fixture()).notebooks.first;
      expect(nb.title, 'Moving day / plans');
      expect(nb.state.entities.keys, containsAll(['maya', 'lisbon']));
      expect(nb.state.entries.single.entityIds, ['maya']);
      expect(nb.state.relations['r1']!.label, 'moving_to');
      expect(nb.state.followUps.single.question, 'How is Maya?');
    });

    test('a malformed export names the key, never a value', () {
      final json = _fixture();
      ((json['notebooks'] as List).first as Map<String, dynamic>)['turns'] =
          'secret journal words';
      expect(
        () => JournalExport.fromJson(json),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('turns'), isNot(contains('secret'))),
        )),
      );
    });
  });

  group('notebookMarkdown', () {
    test('renders the conversation, entries, card and memory', () {
      final md = notebookMarkdown(
        JournalExport.fromJson(_fixture()).notebooks.first,
        toLocal: _utc,
      );
      expect(md, startsWith('# Moving day / plans\n'));
      expect(md, contains('Started Thursday, October 1, 2026, 10:00'));
      expect(md, contains('You talked about Maya moving.'));
      expect(md, contains('**You** · 10:00\n\nI saw Maya today.'));
      expect(md, contains('**Lumen** · 10:00\n\nTell me more.'));
      expect(md, contains('Saw Maya, café on Rue Saint-Honoré.'));
      expect(md, contains('**A card**'));
      expect(md, contains('- Call her'));
      expect(md, contains('- **Maya** (person) — A friend'));
      expect(md, contains('- **Lisbon** (place)'));
      expect(md, contains('- Maya — moving to → Lisbon'));
      expect(md, contains('- [ ] How is Maya?'));
    });

    test('an empty notebook is just its heading and date', () {
      final md = notebookMarkdown(
        JournalExport.fromJson(_fixture()).notebooks.last,
        toLocal: _utc,
      );
      expect(md,
          '# Moving day / plans\n\nStarted Thursday, October 1, 2026, 18:00\n');
    });
  });

  group('export bundle', () {
    test('has the JSON and one Markdown file per notebook', () {
      final export = JournalExport.fromJson(_fixture());
      final vault = buildJournalExportBundle(
        export,
        now: DateTime.utc(2026, 11, 4, 12),
        toLocal: _utc,
      );
      expect(vault.zipName, 'lumen-journal-2026-11-04.zip');
      expect(vault.files.keys, [
        'lumen-journal.json',
        // Same date and same title: the second gets a suffix, not a clash.
        'Notebooks/2026-10-01 Moving day - plans.md',
        'Notebooks/2026-10-01 Moving day - plans (2).md',
      ]);
    });

    test('survives zipping and parses back to the same data', () {
      final json = _fixture();
      final vault = buildJournalExportBundle(JournalExport.fromJson(json));
      final archive = ZipDecoder().decodeBytes(encodeVaultZip(vault));
      final jsonFile = archive.findFile('lumen-journal.json')!;
      final back = JournalExport.fromJson(
        jsonDecode(utf8.decode(jsonFile.content as List<int>))
            as Map<String, dynamic>,
      );
      expect(back.toJson(), json);
      expect(archive.files.where((f) => f.name.endsWith('.md')), hasLength(2));
    });
  });

  group('JournalExportService.fetch', () {
    Map<String, dynamic> response(List<Map<String, dynamic>> notebooks) => {
          'version': 1,
          'exportedAt': '2026-11-04T09:30:00+00:00',
          'notebooks': notebooks,
        };

    Map<String, dynamic> notebook(String id) => {
          ...(_fixture()['notebooks'] as List).last as Map<String, dynamic>,
          'id': id,
        };

    test('asks a chunk at a time, oldest first, and reports progress',
        () async {
      final ids = [for (var i = 5; i >= 1; i--) 'n$i']; // newest first
      final asked = <List<String>>[];
      final progress = <(int, int)>[];
      final service = JournalExportService(
        chunkSize: 2,
        listNotebookIds: () async => ids,
        rpc: (fn, params) async {
          expect(fn, 'export_my_data');
          final chunk = (params['p_notebook_ids'] as List).cast<String>();
          asked.add(chunk);
          return response([for (final id in chunk) notebook(id)]);
        },
      );
      final export =
          await service.fetch(onProgress: (d, t) => progress.add((d, t)));

      expect(asked, [
        ['n1', 'n2'],
        ['n3', 'n4'],
        ['n5'],
      ]);
      expect([for (final n in export.notebooks) n.id],
          ['n1', 'n2', 'n3', 'n4', 'n5']);
      expect(progress, [(0, 5), (2, 5), (4, 5), (5, 5)]);
      expect(export.exportedAt, '2026-11-04T09:30:00+00:00');
    });

    test('no notebooks still yields a valid, empty export', () async {
      final service = JournalExportService(
        listNotebookIds: () async => const [],
        rpc: (fn, params) async => response(const []),
      );
      final export = await service.fetch();
      expect(export.notebooks, isEmpty);
      expect(export.version, 1);
    });
  });
}

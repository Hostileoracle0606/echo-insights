// Files the app writes get a data-protection class: the turn journal (and its
// folder) stay writable once the phone locks; the export zip does not.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/security/file_protection.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/services/turn_journal_service.dart';
import 'package:lumen/models/journal_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('lumen/file_protection');
  late List<MethodCall> calls;
  late Directory directory;

  setUp(() async {
    calls = [];
    directory = await Directory.systemTemp.createTemp('lumen-protection-');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'get' ? 'NSFileProtectionComplete' : null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('protectFile sends the path and class', () async {
    await protectFile('/a/b');
    await protectFile('/a/c', FileProtectionLevel.completeUnlessOpen);
    expect(calls.map((c) => c.arguments), [
      {'path': '/a/b', 'level': 'complete'},
      {'path': '/a/c', 'level': 'completeUnlessOpen'},
    ]);
    expect(await fileProtectionOf('/a/b'), 'NSFileProtectionComplete');
  });

  test('excludeFromBackup names the path; the strict calls throw on failure',
      () async {
    await excludeFromBackup('/a/dir');
    expect(calls.single.method, 'excludeFromBackup');
    expect(calls.single.arguments, {'path': '/a/dir'});
    await protectFileStrict('/a/b');
    expect(calls.last.arguments, {'path': '/a/b', 'level': 'complete'});

    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(excludeFromBackup('/a/dir'), throwsA(anything));
    await expectLater(protectFileStrict('/a/b'), throwsA(anything));
  });

  test('a missing native side never fails a save', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await protectFile('/a/b');
    expect(await fileProtectionOf('/a/b'), isNull);
  });

  test('the export zip is written NSFileProtectionComplete', () async {
    final file = await writeVaultZip(
      buildVault(JournalState.empty()),
      'vault.zip',
      directory: directory,
    );
    expect(calls.single.method, 'set');
    expect(calls.single.arguments, {'path': file.path, 'level': 'complete'});
  });

  test('the turn journal folder and file are completeUnlessOpen', () async {
    final journal =
        TurnJournalService(directoryProvider: () async => directory);
    await journal.persistTurn(
      FinalizedTurn(
        turnId: 't',
        sessionId: 's',
        notebookId: 'n',
        speaker: Speaker.user,
        transcript: 'x',
        transcriptVersion: 1,
        transcriptHash: 'h',
        extractorVersion: 'e',
        generation: 1,
        commitRequestId: 'r',
        stage: DurableStage.finalRecorded,
        finalizedAt: '2026-09-17T12:00:00.000Z',
      ),
    );
    final paths = [for (final c in calls) c.arguments['path'] as String];
    expect(paths.first, endsWith('turn-journal-v1'));
    expect(paths.last, endsWith('n.json.tmp'));
    expect(
      calls.every((c) => c.arguments['level'] == 'completeUnlessOpen'),
      isTrue,
    );
  });
}

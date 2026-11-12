// LM-57, "What Lumen shared": what is logged is the body that was sent,
// kept 7 days on the phone, gone with the session and the account.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/logic/turn_state.dart' show Speaker;
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/privacy/privacy_claims.dart';
import 'package:lumen/providers/shared_log_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/screens/privacy/shared_log_screen.dart';
import 'package:lumen/security/file_protection.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/model_inputs.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/session_card_service.dart';
import 'package:lumen/services/shared_log.dart';
import 'package:lumen/theme/lumen_theme.dart';

import 'support/pseudonyms.dart';

const nb = '8e03b8f4-4f20-4df3-8398-d854adc32b14';
final priya = entity('priya-raman', 'Priya Raman', mentions: 5);

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  late Directory dir;
  late DateTime now;
  late List<(String, FileProtectionLevel)> protections;
  late SharedLog log;
  late List<String> backups;
  Object? protectError;
  Object? backupError;

  SharedLog makeLog({int maxBytes = 256 * 1024}) => SharedLog(
        directoryProvider: () async => dir,
        protect: (path, level) async {
          if (protectError != null) throw protectError!;
          protections.add((path, level));
        },
        excludeFromBackup: (path) async {
          if (backupError != null) throw backupError!;
          backups.add(path);
        },
        now: () => now,
        maxBytes: maxBytes,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shared_log_test');
    now = DateTime.utc(2026, 11, 10, 12);
    protections = [];
    backups = [];
    protectError = null;
    backupError = null;
    log = makeLog();
  });
  tearDown(() {
    // Undo any chmod a test left behind so the folder can go.
    Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
    dir.deleteSync(recursive: true);
  });

  List<File> files() => Directory('${dir.path}/shared-log-v1')
      .listSync()
      .whereType<File>()
      .toList();

  void chmod(String mode, String path) =>
      Process.runSync('chmod', [mode, path]);

  group('the log', () {
    test('lists newest first with kind, time and notebook', () async {
      await log.record(nb, SharedKind.extraction, {'text': 'one'});
      now = now.add(const Duration(minutes: 5));
      await log.record(nb, SharedKind.card, {'text': 'two'});
      final read = await log.read(nb);
      expect(read.map((e) => e.kind), [SharedKind.card, SharedKind.extraction]);
      expect(read.first.body, {'text': 'two'});
      expect(read.first.at, now);
      expect(read.first.notebookId, nb);
    });

    test('the file is one per notebook and protected complete', () async {
      await log.record(nb, SharedKind.extraction, {'text': 'one'});
      await log.record('other', SharedKind.extraction, {'text': 'two'});
      expect(files(), hasLength(2));
      expect(protections, isNotEmpty);
      expect(protections.every((p) => p.$2 == FileProtectionLevel.complete),
          isTrue);
      expect(await log.read('other'), hasLength(1));
    });

    test('sweeps entries older than 7 days on read, on sweep', () async {
      await log.record(nb, SharedKind.extraction, {'text': 'old'});
      now = now.add(const Duration(days: 6, hours: 23));
      await log.record(nb, SharedKind.card, {'text': 'recent'});
      now = now.add(const Duration(hours: 2)); // "old" is now 7d 1h
      expect((await log.read(nb)).map((e) => e.body['text']), ['recent']);

      await log.record('b', SharedKind.draft, {'text': 'x'});
      now = now.add(const Duration(days: 8));
      await log.sweep();
      expect(files(), isEmpty, reason: 'an emptied file is removed');
    });

    test('keeps the newest entries under the size cap', () async {
      log = makeLog(maxBytes: 2000);
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 1));
        await log.record(nb, SharedKind.extraction, {'text': 'x' * 300 + '$i'});
      }
      final read = await log.read(nb);
      expect(read.length, lessThan(20));
      expect(read.first.body['text'], endsWith('19'));
      expect(files().single.lengthSync(), lessThanOrEqualTo(2300));
    });

    test('deleting a session removes its log only', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record('other', SharedKind.extraction, {'t': 2});
      await log.forgetNotebook(nb);
      expect(await log.read(nb), isEmpty);
      expect(await log.read('other'), hasLength(1));
    });

    test('clearAll empties every log', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record('other', SharedKind.card, {'t': 2});
      await log.clearAll();
      expect(files(), isEmpty);
      expect(await log.readAll(), isEmpty);
    });

    test('forgetting a person deletes the whole log, every session', () async {
      await log.record(nb, SharedKind.briefWrite, {'v': 'write'});
      await log.record(nb, SharedKind.briefSpeak, {
        'speak': {'openingLine': 'How is Priya Raman?'}
      });
      await log.record('other', SharedKind.extraction, {'text': 'swapped'});
      await log.forgetPerson();
      expect(files(), isEmpty);
      expect(await log.readAll(), isEmpty);
    });

    test('a damaged file reads as empty and is replaced by the next entry',
        () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      files().single.writeAsStringSync('{not json');
      expect(await log.read(nb), isEmpty);
      await log.record(nb, SharedKind.card, {'t': 2});
      expect(await log.read(nb), hasLength(1));
    });

    test('a write failure never throws', () async {
      final broken = SharedLog(
        directoryProvider: () async => throw const FileSystemException('no'),
      );
      await broken.record(nb, SharedKind.extraction, {'t': 1});
    });

    test('sign-out clears it', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      final container = ProviderContainer(overrides: [
        sharedLogProvider.overrideWithValue(log),
      ]);
      addTearDown(container.dispose);
      // The provider holds what else sign-out clears; read only the part
      // under test by running the same call the cleanup makes.
      container.read(sharedLogProvider).clearAll();
      expect(await log.readAll(), isEmpty);
    });

    test('the cleanup wires the log in', () {
      final source =
          File('lib/providers/voice_services_provider.dart').readAsStringSync();
      expect(source, contains('ref.read(sharedLogProvider).clearAll()'));
      expect(signedOutCleanupProvider, isNotNull);
      final deleteSource =
          File('lib/widgets/delete_session.dart').readAsStringSync();
      expect(deleteSource, contains('.forgetNotebook(notebookId)'));
      expect(deleteSource, contains('sharedLogProvider'));
      final journal =
          File('lib/providers/journal_provider.dart').readAsStringSync();
      expect(
        '_forgetSharedLog();'.allMatches(journal).length,
        2,
        reason: 'forget and removal both clear the log',
      );
    });

    test('exports never read it', () {
      for (final path in [
        'lib/services/markdown_export.dart',
        'lib/services/journal_export_service.dart',
        'lib/providers/export_provider.dart',
      ]) {
        final text = File(path).readAsStringSync();
        expect(text, isNot(contains('shared_log')), reason: path);
        expect(text, isNot(contains('SharedLog')), reason: path);
      }
    });
  });

  group('deletion fails closed (fix round 1)', () {
    test('forgetting deletes a file it cannot read (phone locked)', () async {
      await log.record(nb, SharedKind.briefSpeak, {
        'speak': {'openingLine': 'How is Priya Raman?'}
      });
      await log.record('b', SharedKind.extraction, {'t': 1});
      File('${dir.path}/shared-log-v1/c.json').writeAsStringSync('{not json');
      final locked = files().firstWhere((f) => f.path.contains(nb));
      chmod('000', locked.path);
      await log.forgetPerson();
      expect(files(), isEmpty);
    });

    test('a temp file is removed when the write fails', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      protectError = const FileSystemException('locked');
      await log.record(nb, SharedKind.card, {'t': 2});
      expect(
          Directory('${dir.path}/shared-log-v1').listSync().map((e) => e.path),
          everyElement(endsWith('.json')));
    });

    test('stale temp files go with clear, sweep, notebook and person',
        () async {
      File tmp(String id) => File('${dir.path}/shared-log-v1/$id.json.tmp');
      await log.record(nb, SharedKind.extraction, {'t': 1});
      for (final id in [nb, 'x', 'y', 'z']) {
        tmp(id).writeAsStringSync('{"entries":[]}');
      }
      await log.forgetNotebook(nb);
      expect(tmp(nb).existsSync(), isFalse);
      await log.sweep();
      expect(tmp('x').existsSync(), isFalse);
      await log.clearAll();
      expect(tmp('y').existsSync(), isFalse);
      tmp('z').writeAsStringSync('{}');
      await log.forgetPerson();
      expect(files(), isEmpty);
      expect(
          Directory('${dir.path}/shared-log-v1')
              .listSync()
              .where((e) => e.path.endsWith('.tmp')),
          isEmpty);
    });

    test('a record after a delete does not bring the log back', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.forgetNotebook(nb);
      await log.record(nb, SharedKind.briefSpeak, {
        'speak': {'openingLine': 'Priya Raman'}
      });
      expect(files(), isEmpty);
      await log.record('other', SharedKind.extraction, {'t': 2});
      expect(files(), hasLength(1));
    });

    test('after forgetting a person no speak line is recorded this run',
        () async {
      await log.forgetPerson();
      await log.record(nb, SharedKind.briefSpeak, {
        'speak': {'openingLine': 'Priya Raman'}
      });
      expect(files(), isEmpty);
      await log.record(nb, SharedKind.briefWrite, {'v': 'swapped'});
      expect(await log.read(nb), hasLength(1));
    });

    test('a deletion that failed is retried by the next sweep', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      final folder = '${dir.path}/shared-log-v1';
      chmod('555', folder);
      await expectLater(log.forgetPerson(), throwsA(anything));
      chmod('755', folder);
      expect(files(), isNotEmpty);
      // A new launch.
      await makeLog().sweep();
      expect(files(), isEmpty);
    });

    test('a failed notebook delete is retried by the next sweep', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record('keep', SharedKind.extraction, {'t': 2});
      final folder = '${dir.path}/shared-log-v1';
      chmod('555', folder);
      await expectLater(log.forgetNotebook(nb), throwsA(anything));
      chmod('755', folder);
      await makeLog().sweep();
      expect(files().map((f) => f.path), [endsWith('keep.json')]);
    });

    test('the callers handle a failed deletion', () {
      for (final path in [
        'lib/providers/journal_provider.dart',
        'lib/providers/voice_services_provider.dart',
      ]) {
        final text = File(path).readAsStringSync();
        final at = text.indexOf('sharedLogProvider');
        expect(at, greaterThan(0));
        expect(text, contains('catchError'), reason: path);
      }
      final journal =
          File('lib/providers/journal_provider.dart').readAsStringSync();
      expect(
        RegExp(r'unawaited\(\s*ref\s*\.read\(sharedLogProvider\)\s*\.forgetPerson\(\)\s*\.catchError')
            .allMatches(journal),
        hasLength(1),
        reason: 'the one helper, which handles the failure',
      );
      expect(
        File('lib/providers/voice_services_provider.dart').readAsStringSync(),
        matches(RegExp(r'clearAll\(\)\s*\.catchError')),
      );
    });

    test('a read error in record keeps the history and writes nothing',
        () async {
      await log.record(nb, SharedKind.extraction, {'t': 'old'});
      final file = files().single;
      chmod('000', file.path);
      await log.record(nb, SharedKind.card, {'t': 'new'});
      chmod('644', file.path);
      final read = await log.read(nb);
      expect(read.map((e) => e.body['t']), ['old']);
    });

    test('no file is left unprotected: a failed protect writes nothing',
        () async {
      protectError = const FileSystemException('cannot protect');
      await log.record(nb, SharedKind.extraction, {'t': 1});
      expect(files(), isEmpty);
      expect(await log.read(nb), isEmpty);
    });

    test('a failed backup exclusion writes nothing', () async {
      backupError = const FileSystemException('no');
      await log.record(nb, SharedKind.extraction, {'t': 1});
      expect(files(), isEmpty);
    });

    test('the folder and each file are excluded from backup', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record(nb, SharedKind.card, {'t': 2});
      expect(backups, contains('${dir.path}/shared-log-v1'));
      expect(backups.where((p) => p.endsWith('$nb.json.tmp')), hasLength(2));
    });
  });

  group('pending deletes and the rest of round 2', () {
    File pendingFile() => File('${dir.path}/shared-log-pending');
    void seedPending(Map<String, dynamic> m) =>
        pendingFile().writeAsStringSync(jsonEncode(m));

    test('a seeded "all" is finished by sweep and its file removed', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record('b', SharedKind.briefSpeak, {'t': 2});
      seedPending({'all': true, 'notebooks': []});
      await makeLog().sweep();
      expect(files(), isEmpty);
      expect(pendingFile().existsSync(), isFalse);
    });

    test('seeded notebooks are finished by sweep, the rest kept', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.record('b', SharedKind.extraction, {'t': 2});
      await log.record('keep', SharedKind.extraction, {'t': 3});
      seedPending({
        'all': false,
        'notebooks': [nb, 'b']
      });
      await makeLog().sweep();
      expect(files().map((f) => f.path), [endsWith('keep.json')]);
      expect(pendingFile().existsSync(), isFalse);
    });

    test('a failed delete leaves a pending file that sweep clears', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      final folder = '${dir.path}/shared-log-v1';
      chmod('555', folder);
      await expectLater(log.forgetPerson(), throwsA(anything));
      chmod('755', folder);
      expect(pendingFile().existsSync(), isTrue);
      expect(jsonDecode(pendingFile().readAsStringSync())['all'], isTrue);
      await makeLog().sweep();
      expect(files(), isEmpty);
      expect(pendingFile().existsSync(), isFalse);
    });

    test('the pending file is protected and out of backups; if not, it stays',
        () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      final folder = '${dir.path}/shared-log-v1';
      chmod('555', folder);
      await expectLater(log.forgetNotebook(nb), throwsA(anything));
      chmod('755', folder);
      expect(protections.map((p) => p.$1), contains(pendingFile().path));
      expect(backups, contains(pendingFile().path));

      protectError = const FileSystemException('locked');
      backupError = const FileSystemException('no');
      chmod('555', folder);
      await expectLater(log.forgetPerson(), throwsA(anything));
      chmod('755', folder);
      protectError = null;
      backupError = null;
      expect(pendingFile().existsSync(), isTrue, reason: 'retry still happens');
      await makeLog().sweep();
      expect(files(), isEmpty);
    });

    test('an unreadable or damaged pending file means delete everything',
        () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      pendingFile().writeAsStringSync('{not json');
      await makeLog().sweep();
      expect(files(), isEmpty);
      expect(pendingFile().existsSync(), isFalse);
    });

    test('a file that is not text is skipped by record, deleted by sweep',
        () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      final file = files().single;
      file.writeAsBytesSync([0xff, 0xfe, 0xfd]);
      await log.record(nb, SharedKind.card, {'t': 2});
      expect(file.readAsBytesSync(), [0xff, 0xfe, 0xfd]);
      expect(await log.read(nb), isEmpty);
      await log.sweep();
      expect(files(), isEmpty);
      await log.record(nb, SharedKind.card, {'t': 3});
      file.writeAsBytesSync([0xff, 0xfe]);
      await log.forgetPerson();
      expect(files(), isEmpty);
    });

    test('after sign-out nothing is recorded until the next sign-in', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      await log.clearAll();
      await log.record(nb, SharedKind.extraction, {'t': 2});
      await log.record('other', SharedKind.card, {'t': 3});
      expect(files(), isEmpty);
      log.resume();
      await log.record(nb, SharedKind.extraction, {'t': 4});
      expect(files(), hasLength(1));
    });

    test('a failed wipe is retried before anything is shown', () async {
      await log.record(nb, SharedKind.extraction, {'t': 1});
      seedPending({'all': true, 'notebooks': []});
      final folder = '${dir.path}/shared-log-v1';
      chmod('555', folder);
      expect(await log.read(nb), isEmpty, reason: 'not shown while pending');
      expect(await log.readAll(), isEmpty);
      chmod('755', folder);
      expect(files(), hasLength(1));
      expect(await log.read(nb), isEmpty);
      expect(files(), isEmpty, reason: 'the read finished the wipe');
      expect(pendingFile().existsSync(), isFalse);
    });

    test('the app shares one instance, with launch included', () {
      expect(identical(SharedLog.instance, SharedLog.instance), isTrue);
      expect(File('lib/main.dart').readAsStringSync(),
          contains('SharedLog.instance.sweep()'));
      expect(File('lib/providers/shared_log_provider.dart').readAsStringSync(),
          contains('SharedLog.instance'));
      expect(
          File('lib/providers/voice_services_provider.dart').readAsStringSync(),
          contains('sharedLog.resume()'));
    });
  });

  group('wired at the request', () {
    test('extraction: the logged body is the body sent, no credential',
        () async {
      final sent = <http.Request>[];
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'secret-token-123',
        pseudonyms: testPseudonyms(),
        log: log,
        client: MockClient((request) async {
          sent.add(request);
          return _json({
            'patch': {'entities': [], 'relations': []}
          });
        }),
      );
      await service.extract(
        notebookId: nb,
        turnId: 't1',
        extractorVersion: 'v',
        text: 'I spoke with Priya Raman about the move.',
        state: JournalState.empty(),
        mode: 'granular',
        retrievedEntityIds: const [],
        recentConversation: [(role: Speaker.user, text: 'Hello there.')],
        answeringFollowUp: null,
        maxRetries: 0,
      );
      final logged = await log.read(nb);
      expect(logged, hasLength(1));
      expect(logged.single.kind, SharedKind.extraction);
      expect(logged.single.body, jsonDecode(sent.single.body));
      expect(files().single.readAsStringSync(), isNot(contains('secret')));
      expect(
          files().single.readAsStringSync(), isNot(contains('authorization')));
    });

    test('a retried extraction is one entry', () async {
      var calls = 0;
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: testPseudonyms(),
        log: log,
        client: MockClient((request) async {
          calls++;
          return calls == 1
              ? _json({'code': 'x'}, 503)
              : _json({
                  'patch': {'entities': [], 'relations': []}
                });
        }),
      );
      await service.extract(
        notebookId: nb,
        turnId: 't1',
        extractorVersion: 'v',
        text: 'A turn long enough to send.',
        state: JournalState.empty(),
        mode: 'granular',
        retrievedEntityIds: const [],
        recentConversation: const [],
        answeringFollowUp: null,
        maxRetries: 1,
      );
      expect(calls, 2);
      expect(await log.read(nb), hasLength(1));
    });

    for (final draft in [false, true]) {
      test(
          '${draft ? 'draft' : 'close'}: logged body equals the body sent, '
          'with names swapped', () async {
        final sent = <http.Request>[];
        final service = SessionCardService(
          baseUrl: 'https://runtime.test',
          accessTokenProvider: () async => 'secret-token-123',
          retryBaseDelay: Duration.zero,
          inputs: FixedInputs(
            cardInput: CardInput(
              revision: 7,
              turns: const [
                (
                  speaker: 'user',
                  text: 'Priya Raman is moving away.',
                  spokenAt: null
                ),
              ],
              candidates: [priya],
            ),
          ),
          pseudonyms: testPseudonyms(),
          log: log,
          rpc: (fn, [params]) async => {'status': 'saved'},
          client: MockClient((request) async {
            sent.add(request);
            return _json({'status': 'rejected'}, 422);
          }),
        );
        if (draft) {
          await service.draft(nb);
        } else {
          await service.close(nb);
        }
        final logged = await log.read(nb);
        expect(logged.single.kind, draft ? SharedKind.draft : SharedKind.card);
        expect(logged.single.body, jsonDecode(sent.single.body));
        expect(jsonEncode(logged.single.body), isNot(contains('Priya')));
        expect(files().single.readAsStringSync(), isNot(contains('secret')));
      });
    }

    test('brief: write and speak are logged as sent, minus the speak token',
        () async {
      final sent = <Map<String, dynamic>>[];
      final headers = <Map<String, String>>[];
      final service = SessionBriefService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'secret-token-123',
        inputs: FixedInputs(
          briefInput: BriefInput(
            revision: 7,
            turns: const [
              (
                speaker: 'user',
                text: 'Priya Raman is moving away.',
                spokenAt: null
              ),
            ],
            previous: null,
            followUps: const [],
            questions: const [],
            topEntities: const [(name: 'Priya Raman', type: 'person')],
            entities: [priya],
          ),
        ),
        pseudonyms: testPseudonyms(),
        log: log,
        rpc: (fn, [params]) async => {'status': 'saved'},
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(body);
          headers.add(request.headers);
          if (body['speak'] != null) {
            return _json({
              'status': 'ready',
              'audioBase64': 'UENN',
              'sampleRate': 24000,
              'openingLine': (body['speak'] as Map)['openingLine'],
              'sourceRevision': 7,
            });
          }
          final fake = ((body['topEntities'] as List).single as Map)['name'];
          return _json({
            'status': 'ready',
            'sourceRevision': 7,
            'speakToken': 'speak-ticket-xyz',
            'brief': {
              'focus': ['$fake is moving'],
              'openingThread': "$fake's move",
              'openingLine': 'How is $fake doing?',
            },
          });
        }),
      );
      await service.requestBrief(nb);
      expect(sent, hasLength(2));
      expect(sent.last['speak']['speakToken'], 'speak-ticket-xyz');
      expect(headers.last['authorization'], contains('secret-token-123'));

      final logged = (await log.read(nb)).reversed.toList();
      expect(logged.map((e) => e.kind),
          [SharedKind.briefWrite, SharedKind.briefSpeak]);
      expect(logged[0].body, sent[0]);
      expect(jsonEncode(logged[0].body), isNot(contains('Priya')));
      // The speak request, minus its token; its line holds the real name.
      expect(logged[1].body, {
        'version': 2,
        'speak': {'openingLine': sent[1]['speak']['openingLine']},
      });
      expect(logged[1].carriesRealNames, isTrue);
      expect(logged[1].body['speak']['openingLine'], contains('Priya Raman'));

      final onDisk = files().single.readAsStringSync();
      for (final secret in [
        'secret-token-123',
        'speak-ticket-xyz',
        'speakToken',
        'authorization',
        'Bearer',
      ]) {
        expect(onDisk, isNot(contains(secret)));
      }
    });

    test('nothing sent, nothing logged: signed out, and no user turn',
        () async {
      final service = SessionCardService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        inputs: FixedInputs(
          cardInput: CardInput(
            revision: 7,
            turns: const [(speaker: 'user', text: 'Hi', spokenAt: null)],
            candidates: [priya],
          ),
        ),
        pseudonyms: testPseudonyms(owner: null),
        log: log,
        rpc: (fn, [params]) async => null,
        client: MockClient((request) async => _json({})),
      );
      await expectLater(service.close(nb), throwsStateError);
      expect(await log.readAll(), isEmpty);
    });

    test('off the record: the log is only written where a request is sent', () {
      // LM-50 sends no extraction, draft, card or brief request while off
      // the record (asserted end to end in off_the_record_test.dart, which
      // also checks the log stays empty). Logging has no other call site.
      final callers = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f.readAsStringSync().contains('.record('))
          .map((f) => f.path.split('/').last)
          .where((n) => n != 'shared_log.dart')
          .toSet();
      expect(callers, {
        'extract_graph_service.dart',
        'session_card_service.dart',
        'session_brief_service.dart',
      });
    });
  });

  group('copy', () {
    test('the claim says what is kept and what is not', () {
      expect(sharedLogClaim, contains('exactly what Lumen sent'));
      expect(sharedLogClaim, contains('7 days'));
      expect(sharedLogClaim, contains('live voice conversation is not'));
      expect(sharedLogClaim, contains('Forgetting a person clears it'));
      expect(File('src/routes/security.tsx').readAsStringSync(),
          contains(sharedLogClaim));
    });
  });

  group('viewer', () {
    // A fake: real file I/O doesn't complete inside a widget test's clock.
    Future<void> open(
      WidgetTester tester,
      List<SharedRequest> entries, {
      String? notebookId,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedLogProvider.overrideWithValue(_FakeLog(entries))],
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: SharedLogScreen(notebookId: notebookId),
        ),
      ));
      await tester.pumpAndSettle();
    }

    SharedRequest entry(SharedKind kind, DateTime at, Map<String, dynamic> b) =>
        SharedRequest(kind: kind, at: at, notebookId: nb, body: b);

    testWidgets('empty state and the static voice note', (tester) async {
      await open(tester, const [], notebookId: nb);
      expect(find.byKey(const Key('sharedLogEmpty')), findsOneWidget);
      expect(find.byKey(const Key('sharedLogVoiceNote')), findsOneWidget);
      expect(find.textContaining("isn't swapped"), findsOneWidget);
    });

    testWidgets('lists newest first; expands to the exact text; labels speak',
        (tester) async {
      await open(tester, [
        entry(SharedKind.briefSpeak, DateTime.utc(2026, 11, 10, 12, 1), {
          'speak': {'openingLine': 'How is Priya Raman?'}
        }),
        entry(SharedKind.extraction, DateTime.utc(2026, 11, 10, 12),
            {'text': 'First swapped'}),
      ]);

      final speak = tester.getTopLeft(find.text('Brief: speaking'));
      final extraction = tester.getTopLeft(find.text('Extraction'));
      expect(speak.dy, lessThan(extraction.dy), reason: 'newest first');
      expect(find.textContaining('contains a real name'), findsOneWidget);
      expect(find.textContaining('First swapped'), findsNothing);

      await tester.tap(find.text('Extraction'));
      await tester.pumpAndSettle();
      expect(find.textContaining('First swapped'), findsOneWidget);
      await tester.tap(find.text('Brief: speaking'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sharedLogRealNameNote')), findsOneWidget);
      expect(find.textContaining('How is Priya Raman?'), findsOneWidget);
    });
  });
}

class _FakeLog implements SharedLog {
  _FakeLog(this.entries);
  final List<SharedRequest> entries;

  @override
  Future<List<SharedRequest>> read(String notebookId) async => entries;

  @override
  Future<List<SharedRequest>> readAll() async => entries;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

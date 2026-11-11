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

  SharedLog makeLog({int maxBytes = 256 * 1024}) => SharedLog(
        directoryProvider: () async => dir,
        protect: (path, level) async => protections.add((path, level)),
        now: () => now,
        maxBytes: maxBytes,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shared_log_test');
    now = DateTime.utc(2026, 11, 10, 12);
    protections = [];
    log = makeLog();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<File> files() => Directory('${dir.path}/shared-log-v1')
      .listSync()
      .whereType<File>()
      .toList();

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

    test('forgetting a person deletes every speak entry, keeps the rest',
        () async {
      await log.record(nb, SharedKind.briefWrite, {'v': 'write'});
      await log.record(nb, SharedKind.briefSpeak, {
        'speak': {'openingLine': 'How is Priya Raman?'}
      });
      await log.record('only-speak', SharedKind.briefSpeak, {
        'speak': {'openingLine': 'Hi Sam'}
      });
      await log.forgetSpeakEntries();
      final all = await log.readAll();
      expect(all.map((e) => e.kind), [SharedKind.briefWrite]);
      expect(files(), hasLength(1));
      expect(files().single.readAsStringSync(), isNot(contains('Priya')));
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
        'forgetSpeakEntries'.allMatches(journal).length,
        2,
        reason: 'forget and removal both clear speak lines',
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

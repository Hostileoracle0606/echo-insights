// Timing marks at the points where the person waits, through the real
// JournalNotifier and GeminiLiveClient. Only the socket, the microphone, the
// speaker and the token source are fakes; the marks go to a recording sink.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/timing_marks.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/timing_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/retrieve_memory_service.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/services/transcript_store.dart';
import 'package:lumen/services/turn_journal_service.dart';

import 'support/fake_live_socket.dart';

const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

class _FakeMic implements MicCapture {
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {}
  @override
  Future<void> stop() async {}
}

class _Speaker implements PcmAudioBackend {
  @override
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// A notebook with an earlier entry (it continues: no greeting) and
/// [entities] entities.
class _FakeCommits implements NotebookCommitService {
  _FakeCommits(this.entities);
  final int entities;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async {
    final at = DateTime.utc(2026, 10, 20, 12);
    return NotebookSnapshot(
      notebookId: notebookId,
      revision: 3,
      state: JournalState.empty().copyWith(
        entries: [
          JournalEntry(
            id: 'entry-1',
            text: 'Earlier.',
            createdAt: at,
            entityIds: const [],
            relationIds: const [],
          ),
        ],
        entities: {
          for (var i = 0; i < entities; i++)
            'e$i': Entity(
              id: 'e$i',
              name: 'Entity $i',
              type: EntityType.concept,
              metadata: const {},
              mentions: 1,
              firstSeen: at,
              lastSeen: at,
            ),
        },
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  @override
  Future<void> persistTurn(FinalizedTurn turn) async {}
  @override
  Future<void> forgetTurn({
    required String notebookId,
    required String turnId,
  }) async {}
  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(
          String notebookId) async =>
      const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTranscripts implements TranscriptStore {
  @override
  Future<List<ConversationTurn>> load(String notebookId,
          {int limit = 500}) async =>
      const [];
  @override
  Future<void> save(String notebookId, ConversationTurn turn) async {}
}

class _NoNotebookInserts implements SupabaseService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected Supabase call: ${invocation.memberName}');
}

/// Every description edit fails, so the notebook reloads its snapshot.
class _FailingMemoryControl implements MemoryControlService {
  @override
  Future<int> editDescription(String entityId, String text) async =>
      throw Exception('offline');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({int entities = 50}) {
    credentials = LiveCredentials(fetch: () async {
      final now = DateTime.now();
      return LiveSessionReady(
        sessionToken: 'auth_tokens/t${now.microsecondsSinceEpoch}',
        expiresAt: now.add(const Duration(minutes: 30)),
        newSessionExpiresAt: now.add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    container = ProviderContainer(overrides: [
      timingMarksProvider.overrideWithValue(marks),
      memoryControlServiceProvider.overrideWithValue(_FailingMemoryControl()),
      notebookCommitServiceProvider.overrideWithValue(_FakeCommits(entities)),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(_FakeTranscripts()),
      supabaseServiceProvider.overrideWithValue(_NoNotebookInserts()),
      liveCredentialsProvider.overrideWithValue(credentials),
      audioOutputProvider.overrideWithValue(
        AudioOutput(createPlayer: () => PcmPlayer(backend: _Speaker())),
      ),
      micCaptureFactoryProvider.overrideWithValue(() => _FakeMic()),
      echoCancellationProvider.overrideWithValue(() async => true),
      speechEndGraceProvider
          .overrideWithValue(const Duration(milliseconds: 20)),
      liveClientFactoryProvider.overrideWithValue(
        ({required String sessionToken, required String model}) =>
            GeminiLiveClient(
          sessionToken: sessionToken,
          model: model,
          systemInstruction: 'system',
          voice: 'Aoede',
          tools: const [],
          channelFactory: (uri) {
            final socket = FakeLiveSocket(uri);
            sockets.add(socket);
            return socket;
          },
        ),
      ),
    ]);
    credentials.start();
  }

  final lines = <String>[];
  late final marks =
      TimingMarks(enabled: true, mode: 'profile', sink: lines.add)..start();
  late final ProviderContainer container;
  late final LiveCredentials credentials;
  final sockets = <FakeLiveSocket>[];

  JournalNotifier get journal => container.read(journalProvider.notifier);
  FakeLiveSocket get socket => sockets.last;

  List<Map<String, dynamic>> get recorded => [
        for (final line in lines)
          jsonDecode(line.substring(timingLinePrefix.length + 1))
              as Map<String, dynamic>,
      ];

  List<Map<String, dynamic>> stage(String name) =>
      recorded.where((m) => m['stage'] == name).toList();

  Future<void> startLive() async {
    await journal.enterNotebook(_notebookId);
    final starting = journal.startSession();
    for (var i = 0; i < 200 && sockets.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await starting).succeeded, isTrue);
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void dispose() {
    credentials.stop();
    container.dispose();
  }
}

Map<String, dynamic> _userFinished() => {
      'serverContent': {
        'inputTranscription': {'text': 'I went for a run.', 'finished': true},
      },
    };

Map<String, dynamic> _userSays(String text) => {
      'serverContent': {
        'inputTranscription': {'text': text},
      },
    };

Map<String, dynamic> _lumenAudio() => {
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {
                'mimeType': 'audio/pcm;rate=24000',
                'data': base64.encode(Uint8List(2400)),
              },
            },
          ],
        },
      },
    };

class _Briefs implements SessionBriefService {
  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: true, brief: null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Map<String, dynamic>> _decode(List<String> lines) => [
      for (final line in lines)
        jsonDecode(line.substring(timingLinePrefix.length + 1))
            as Map<String, dynamic>,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('retrieval', () {
    late List<String> lines;
    late TimingMarks marks;
    setUp(() {
      lines = [];
      marks = TimingMarks(enabled: true, mode: 'profile', sink: lines.add)
        ..start();
    });

    Future<Map<String, dynamic>> spanFor(RetrieveMemoryInvoker invoke,
        {Duration? timeout}) async {
      await RetrieveMemoryService.withInvoker(invoke, timing: marks)
          .retrieveResult(
        query: 'the move',
        notebookId: 'nb',
        scope: RetrievalScope.user,
        timeout: timeout,
      );
      return _decode(lines).single;
    }

    test('a retrieval that answers is ok, with its entity count', () async {
      final span = await spanFor((_) async => {
            'version': 2,
            'context': 'ctx',
            'entityIds': ['a', 'b'],
            'quotes': <Object>[],
          });
      expect(span['stage'], 'retrieval');
      expect(span['phase'], 'span');
      expect(span['ok'], isTrue);
      expect(span['count'], 2);
      expect(span['scope'], RetrievalScope.user.index);
    });

    test('an error is not ok: it never passes for a fast answer', () async {
      final span = await spanFor((_) async => throw Exception('network'));
      expect(span['ok'], isFalse);
      expect(span['count'], 0);
    });

    test('a timeout is not ok: it never passes for a slow answer', () async {
      final span = await spanFor((_) => Completer<dynamic>().future,
          timeout: const Duration(milliseconds: 10));
      expect(span['ok'], isFalse);
    });
  });

  group('opening_prep', () {
    test('records overlap only when it ran during a live session', () async {
      final lines = <String>[];
      final marks = TimingMarks(enabled: true, mode: 'profile', sink: lines.add)
        ..start();
      final prep = OpeningPrep(_Briefs(), timing: marks);

      await prep.refresh();
      marks.turnActive = true;
      await prep.refresh();

      final spans = _decode(lines);
      expect(spans.map((m) => m['stage']), ['opening_prep', 'opening_prep']);
      expect(spans.map((m) => m['phase']), ['span', 'span']);
      expect(spans.map((m) => m['overlap']), [false, true]);
      expect(spans.map((m) => m['ok']), [true, true]);
    });
  });

  testWidgets('home_interactive is marked once, when notebooks first show',
      (tester) async {
    final lines = <String>[];
    final marks = TimingMarks(enabled: true, mode: 'profile', sink: lines.add)
      ..start();
    final now = DateTime.now();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        timingMarksProvider.overrideWithValue(marks),
        notebooksProvider.overrideWith((ref) => [
              Notebook(
                id: '1',
                userId: 'demo',
                title: 'Atlas',
                titleSource: 'ai',
                startedAt: now,
                endedAt: now,
                entityCount: 50,
                summary: null,
                createdAt: now,
                updatedAt: now,
              ),
            ]),
      ],
      child:
          MaterialApp(theme: LumenTheme.light(), home: const DashboardScreen()),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final home = _decode(lines).where((m) => m['stage'] == 'home_interactive');
    expect(home, hasLength(1));
    expect(home.single['size'], entityCountBucket(50));
    expect(home.single['count'], 1);
    expect(lines.join(), isNot(contains('Atlas')));
  });

  group('journal', () {
    late _Harness h;
    tearDown(() => h.dispose());

    test('opening a seeded notebook marks notebook_open begin and end',
        () async {
      h = _Harness(entities: 50);

      await h.journal.enterNotebook(_notebookId);

      final open = h.stage('notebook_open');
      expect(open.map((m) => m['phase']), ['begin', 'end']);
      expect(open.last['dur_ms'], isA<int>());
      expect(open.last['size'], entityCountBucket(50));
      expect(open.last.containsKey('incomplete'), isFalse);
    });

    test('a mic tap marks tap_to_mic_open once the mic records', () async {
      h = _Harness();

      await h.startLive();

      final mic = h.stage('tap_to_mic_open');
      expect(mic.map((m) => m['phase']), ['begin', 'end']);
      expect(mic.last.containsKey('incomplete'), isFalse);
    });

    test('first assistant audio after a user turn ends is marked once per turn',
        () async {
      h = _Harness();
      await h.startLive();

      for (var turn = 0; turn < 2; turn++) {
        h.socket.serverSends(_userFinished());
        await h.settle();
        h.socket
          ..serverSends(_lumenAudio())
          ..serverSends(_lumenAudio())
          ..serverSends(_lumenAudio())
          ..serverSends({
            'serverContent': {'turnComplete': true},
          });
        await h.settle();
      }

      final waits = h.stage('user_turn_end_to_first_audio');
      expect(waits.map((m) => m['phase']), ['span', 'span']);
      expect(waits.every((m) => m['dur_ms'] is int), isTrue);
    });

    // Gemini's input transcription has no ordering guarantee against the
    // reply: the final chunk can land after the reply's audio started, or
    // only with turnComplete. Neither may start a wait of its own.
    test('a final transcript arriving mid-reply does not start a new wait',
        () async {
      h = _Harness();
      await h.startLive();

      h.socket.serverSends(_userSays('I went for'));
      await h.settle();
      h.socket.serverSends(_lumenAudio());
      await h.settle();
      h.socket
        ..serverSends(_userFinished())
        ..serverSends(_lumenAudio())
        ..serverSends({
          'serverContent': {'turnComplete': true},
        });
      await h.settle();

      final waits = h.stage('user_turn_end_to_first_audio');
      expect(waits.map((m) => m['phase']), ['span']);
    });

    test('a final transcript that comes with turnComplete is not a new turn',
        () async {
      h = _Harness();
      await h.startLive();

      h.socket.serverSends(_userSays('I went for'));
      await h.settle();
      h.socket.serverSends(_lumenAudio());
      await h.settle();
      h.socket
        ..serverSends(_userFinished())
        ..serverSends({
          'serverContent': {'turnComplete': true},
        });
      await h.settle();
      // The next turn: its wait is measured from its own speech.
      h.socket.serverSends(_userSays('Then I slept'));
      await h.settle();
      h.socket.serverSends(_lumenAudio());
      await h.settle();

      final waits = h.stage('user_turn_end_to_first_audio');
      expect(waits.map((m) => m['phase']), ['span', 'span']);
      expect(waits.where((m) => m['incomplete'] == true), isEmpty);
    });

    test('a turn Lumen never answers with audio counts as incomplete',
        () async {
      h = _Harness();
      await h.startLive();

      h.socket.serverSends(_userFinished());
      await h.settle();
      h.socket.serverSends({
        'serverContent': {'turnComplete': true},
      });
      await h.settle();

      final waits = h.stage('user_turn_end_to_first_audio');
      expect(waits.map((m) => m['incomplete']), [true]);
    });

    test('a snapshot reload is a span that records overlap with a session',
        () async {
      h = _Harness();
      await h.journal.enterNotebook(_notebookId);
      await expectLater(
          h.journal.editEntityDescription('e1', 'new words'), throwsException);
      await h.startLive();
      await expectLater(
          h.journal.editEntityDescription('e1', 'more words'), throwsException);

      final reloads = h.stage('snapshot_reload');
      expect(reloads.map((m) => m['phase']), ['span', 'span']);
      expect(reloads.map((m) => m['overlap']), [false, true]);
      expect(reloads.map((m) => m['ok']), [true, true]);
    });

    test('no line carries transcript text', () async {
      h = _Harness();
      await h.startLive();
      h.socket.serverSends(_userFinished());
      await h.settle();
      expect(h.lines.join('\n'), isNot(contains('run')));
    });
  });
}

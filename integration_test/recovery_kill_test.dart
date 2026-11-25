// Recovery kill test, run on the iOS Simulator by eval/recovery/kill.sh,
// which kills the app mid-turn with `simctl terminate` and runs this again to
// resume. Not meant to be run by hand: phase "start" never finishes on its own.
//
// What is real: JournalNotifier and its turn machine, the on-device turn
// journal file, Supabase (local stack) for the notebook commit and
// conversation_turns, and extraction through the app's ExtractGraphService to
// NOTEBOOK_RUNTIME_URL, where eval/recovery/gateway-server.mjs runs the real
// extraction Lambda with a stubbed model. What is fake: the Gemini Live
// socket and its token, the microphone and the speaker, so no provider is
// called.
//
//   start  — turn 1 typed and committed, then turn 2: typed (case
//            "extraction") or still being transcribed (case "transcription");
//            then waits to be killed.
//   resume — reopens the notebook, which replays the turn journal, and waits
//            for it to drain.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../test/support/fake_live_socket.dart';

const _phase = String.fromEnvironment('RECOVERY_PHASE');
const _case = String.fromEnvironment('RECOVERY_CASE');
const _email = String.fromEnvironment('RECOVERY_EMAIL');
const _password = String.fromEnvironment('RECOVERY_PASSWORD');
const _notebookId = String.fromEnvironment('RECOVERY_NOTEBOOK_ID');
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

// eval/recovery/fixtures/patches.json, turns t1 and t2.
const _turn1 = 'Started the Lantern Bay garden plot with Odette this morning.';
const _turn2 = 'Odette introduced me to Imre, who keeps bees near the north fence.';

void mark(String message) => debugPrintSynchronously('[recovery-kill] $message');

class _Mic implements MicCapture {
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

Future<bool> _until(Future<bool> Function() done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (await done()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recovery kill: $_phase/$_case', (tester) async {
    expect(_phase, anyOf('start', 'resume'));
    expect(_notebookId, isNotEmpty);

    await Supabase.initialize(url: _supabaseUrl, publishableKey: _anonKey);
    await Supabase.instance.client.auth
        .signInWithPassword(email: _email, password: _password);

    final sockets = <FakeLiveSocket>[];
    final credentials = LiveCredentials(fetch: () async {
      final now = DateTime.now();
      return LiveSessionReady(
        sessionToken: 'auth_tokens/recovery-${now.microsecondsSinceEpoch}',
        expiresAt: now.add(const Duration(minutes: 30)),
        newSessionExpiresAt: now.add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    final container = ProviderContainer(overrides: [
      liveCredentialsProvider.overrideWithValue(credentials),
      audioOutputProvider.overrideWithValue(
        AudioOutput(createPlayer: () => PcmPlayer(backend: _Speaker())),
      ),
      micCaptureFactoryProvider.overrideWithValue(() => _Mic()),
      echoCancellationProvider.overrideWithValue(() async => true),
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
    final journal = container.read(journalProvider.notifier);
    final turnJournal = container.read(turnJournalServiceProvider);
    Future<int> checkpoints() async =>
        (await turnJournal.loadCheckpoints(_notebookId)).length;

    if (_phase == 'resume') {
      final found = await checkpoints();
      mark('resume found=$found');
      final opened = await journal.enterNotebook(_notebookId);
      expect(opened.succeeded, isTrue);
      final drained = await _until(
          () async => await checkpoints() == 0, const Duration(seconds: 30));
      mark('resume done drained=$drained left=${await checkpoints()}');
      credentials.stop();
      return;
    }

    expect(_case, anyOf('transcription', 'extraction'));
    final opened = await journal.enterNotebook(_notebookId);
    expect(opened.succeeded, isTrue);
    final starting = journal.startSession();
    await _until(() async => sockets.isNotEmpty, const Duration(seconds: 10));
    sockets.last
      ..serverSends({'setupComplete': <String, dynamic>{}})
      ..serverSends({
        'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
      });
    expect((await starting).succeeded, isTrue);
    mark('live');

    final entriesBefore = container.read(journalProvider).entries.length;
    expect(journal.sendTypedTurn(_turn1), isTrue);
    final committed = await _until(
      () async =>
          container.read(journalProvider).entries.length > entriesBefore &&
          await checkpoints() == 0,
      const Duration(seconds: 30),
    );
    expect(committed, isTrue, reason: 'turn 1 never committed');
    mark('turn1 committed');

    if (_case == 'extraction') {
      expect(journal.sendTypedTurn(_turn2), isTrue);
      mark('turn2 submitted');
    } else {
      // The user is mid-sentence: Gemini has streamed part of the input
      // transcription and nothing has finalized it.
      sockets.last.serverSends({
        'serverContent': {
          'inputTranscription': {'text': 'Odette introduced me to Imre, who'},
        },
      });
      mark('turn2 transcribing');
    }

    // Report if the turn finished before the kill came (the kill then tested
    // nothing), then wait to be killed.
    final finished = await _until(
      () async =>
          container.read(journalProvider).entries.length > entriesBefore + 1 &&
          await checkpoints() == 0,
      const Duration(seconds: 20),
    );
    mark(finished ? 'turn2 committed before kill' : 'turn2 still open');
    await Future<void>.delayed(const Duration(minutes: 5));
  }, timeout: const Timeout(Duration(minutes: 6)));
}

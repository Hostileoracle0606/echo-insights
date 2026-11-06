import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/session_brief_service.dart';

class _NoBriefs implements SessionBriefService {
  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: false, brief: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend implements PcmAudioBackend {
  @override
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late int fetches;
  late int players;
  late LiveCredentials credentials;
  late AudioOutput output;

  setUp(() {
    fetches = 0;
    players = 0;
    credentials = LiveCredentials(fetch: () async {
      fetches += 1;
      return LiveSessionReady(
        sessionToken: 'auth_tokens/t$fetches',
        expiresAt: DateTime.now().add(const Duration(minutes: 30)),
        newSessionExpiresAt: DateTime.now().add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    output = AudioOutput(createPlayer: () {
      players += 1;
      return PcmPlayer(backend: _Backend());
    });
  });

  tearDown(() async {
    credentials.stop();
    await output.stop();
  });

  test('sign-in fetches a token and starts the player; sign-out clears both',
      () async {
    final binding =
        VoiceServicesBinding(credentials: credentials, audioOutput: output);

    binding.signedInChanged(true);
    await pumpEventQueue();
    expect(fetches, 1);
    expect(credentials.phase, LiveCredentialsPhase.held);
    expect(output.player, isNotNull);

    binding.signedInChanged(false);
    await pumpEventQueue();
    expect(credentials.phase, LiveCredentialsPhase.none);
    expect(output.player, isNull);
  });

  test('sign-in warms what the first notebook open reads, once', () async {
    var warmUps = 0;
    final binding = VoiceServicesBinding(
      credentials: credentials,
      audioOutput: output,
      warmUp: () async => warmUps += 1,
    );

    binding.signedInChanged(true);
    binding.signedInChanged(true);
    await pumpEventQueue();

    expect(warmUps, 1);
  });

  test('resuming calls onResume', () async {
    var resumes = 0;
    final binding = VoiceServicesBinding(
      credentials: credentials,
      audioOutput: output,
      onResume: () async => resumes += 1,
    );

    binding.lifecycleChanged(AppLifecycleState.resumed);
    expect(resumes, 0, reason: 'ignored while signed out');
    binding.signedInChanged(true);
    binding.lifecycleChanged(AppLifecycleState.resumed);
    await pumpEventQueue();

    expect(resumes, 1);
  });

  test("sign-out clears the account's forgotten ids", () {
    final container = ProviderContainer(overrides: [
      openingPrepProvider.overrideWithValue(OpeningPrep(_NoBriefs())),
    ]);
    addTearDown(container.dispose);
    container.read(forgottenThisRunProvider).add('maya-chen');

    container.read(signedOutCleanupProvider)();
    expect(container.read(forgottenThisRunProvider), isEmpty);
  });

  test('sign-out calls onSignedOut', () async {
    var cleared = 0;
    final binding = VoiceServicesBinding(
      credentials: credentials,
      audioOutput: output,
      onSignedOut: () => cleared += 1,
    );

    binding.signedInChanged(true);
    expect(cleared, 0);
    binding.signedInChanged(false);
    await pumpEventQueue();

    expect(cleared, 1);
  });

  test('repeated auth events do not restart the services', () async {
    final binding =
        VoiceServicesBinding(credentials: credentials, audioOutput: output);

    binding.signedInChanged(true);
    binding.signedInChanged(true);
    await pumpEventQueue();

    expect(fetches, 1);
    expect(players, 1);
  });

  test('without a runtime URL only the player starts', () async {
    final binding = VoiceServicesBinding(
      credentials: credentials,
      audioOutput: output,
      runtimeConfigured: false,
    );

    binding.signedInChanged(true);
    await pumpEventQueue();

    expect(fetches, 0);
    expect(output.player, isNotNull);
  });

  test('lifecycle is ignored while signed out', () async {
    final binding =
        VoiceServicesBinding(credentials: credentials, audioOutput: output);

    binding.lifecycleChanged(AppLifecycleState.resumed);
    await pumpEventQueue();

    expect(fetches, 0);
    expect(players, 0);
  });
}

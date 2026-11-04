// Quiet mode: Lumen speaks aloud only into headphones or Bluetooth.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_route.dart';
import 'package:lumen/audio/voice_engine.dart';
import 'package:lumen/providers/quiet_mode_provider.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_provider.dart';

class _Engine extends VoiceEngine {
  final routes = StreamController<AudioRoute>.broadcast();
  @override
  Stream<AudioRoute> routeChanges() => routes.stream;
}

class _Store implements PrivacyPreferenceStore {
  _Store(this.quiet);
  final bool quiet;
  @override
  Future<bool> read(String key) async => key == quietModeKey && quiet;
  @override
  Future<void> write(String key, bool value) async {}
}

void main() {
  test('off: every route plays', () {
    for (final route in AudioRoute.values) {
      expect(quietModeAllowsPlayback(quietMode: false, route: route), isTrue);
    }
  });

  test('on: headphones and Bluetooth play', () {
    expect(
      quietModeAllowsPlayback(quietMode: true, route: AudioRoute.headphones),
      isTrue,
    );
    expect(
      quietModeAllowsPlayback(quietMode: true, route: AudioRoute.bluetooth),
      isTrue,
    );
  });

  test('on: the built-in speaker stays silent', () {
    expect(
      quietModeAllowsPlayback(quietMode: true, route: AudioRoute.builtIn),
      isFalse,
    );
  });

  test('on: AirPlay, car audio and an unreadable route stay silent', () {
    expect(
      quietModeAllowsPlayback(quietMode: true, route: AudioRoute.other),
      isFalse,
    );
    expect(
      quietModeAllowsPlayback(quietMode: true, route: AudioRoute.unknown),
      isFalse,
    );
  });

  test('parses what the native side sends', () {
    expect(AudioRoute.parse('builtIn'), AudioRoute.builtIn);
    expect(AudioRoute.parse('headphones'), AudioRoute.headphones);
    expect(AudioRoute.parse('bluetooth'), AudioRoute.bluetooth);
    expect(AudioRoute.parse('other'), AudioRoute.other);
    expect(AudioRoute.parse(null), AudioRoute.unknown);
    expect(AudioRoute.parse('nonsense'), AudioRoute.unknown);
  });

  group('provider', () {
    Future<(ProviderContainer, _Engine)> open({required bool quiet}) async {
      final engine = _Engine();
      final container = ProviderContainer(overrides: [
        voiceEngineProvider.overrideWithValue(engine),
        privacyPreferenceStoreProvider.overrideWithValue(_Store(quiet)),
      ]);
      addTearDown(container.dispose);
      container.listen(quietPlaybackAllowedProvider, (_, __) {});
      await Future<void>.delayed(Duration.zero);
      return (container, engine);
    }

    test('off by default: plays on the speaker', () async {
      final (container, engine) = await open(quiet: false);
      engine.routes.add(AudioRoute.builtIn);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietPlaybackAllowedProvider), isTrue);
    });

    test('on: follows the route as headphones come and go', () async {
      final (container, engine) = await open(quiet: true);
      expect(container.read(quietModeProvider), isTrue);
      // Route unknown until the engine says.
      expect(container.read(quietPlaybackAllowedProvider), isFalse);
      engine.routes.add(AudioRoute.headphones);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietPlaybackAllowedProvider), isTrue);
      engine.routes.add(AudioRoute.builtIn);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(quietPlaybackAllowedProvider), isFalse);
    });
  });
}

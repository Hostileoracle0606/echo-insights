import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_route.dart';
import '../audio/voice_engine.dart';
import '../security/app_lock.dart';
import '../security/app_lock_provider.dart';

final voiceEngineProvider =
    Provider<VoiceEngine>((ref) => VoiceEngine.instance);

/// Quiet mode switch. Off until the saved value is read.
class QuietModeNotifier extends Notifier<bool> {
  bool _touched = false;

  @override
  bool build() {
    var disposed = false;
    ref.onDispose(() => disposed = true);
    ref.read(privacyPreferenceStoreProvider).read(quietModeKey).then((saved) {
      // A switch flipped before the read lands wins.
      if (!disposed && !_touched) state = saved;
    }, onError: (_) {});
    return false;
  }

  Future<void> set(bool on) async {
    _touched = true;
    state = on;
    await ref.read(privacyPreferenceStoreProvider).write(quietModeKey, on);
  }
}

final quietModeProvider =
    NotifierProvider<QuietModeNotifier, bool>(QuietModeNotifier.new);

/// The live output route. Only read while quiet mode is on.
class AudioRouteNotifier extends Notifier<AudioRoute> {
  @override
  AudioRoute build() {
    final sub = ref.read(voiceEngineProvider).routeChanges().listen(
          (route) => state = route,
          // No native engine (tests, other platforms): stays unknown.
          onError: (_) {},
        );
    ref.onDispose(sub.cancel);
    return AudioRoute.unknown;
  }
}

final audioRouteProvider =
    NotifierProvider<AudioRouteNotifier, AudioRoute>(AudioRouteNotifier.new);

/// Whether Lumen's voice may play aloud now. True whenever quiet mode is off.
final quietPlaybackAllowedProvider = Provider<bool>((ref) {
  final quiet = ref.watch(quietModeProvider);
  if (!quiet) return true;
  return quietModeAllowsPlayback(
    quietMode: quiet,
    route: ref.watch(audioRouteProvider),
  );
});

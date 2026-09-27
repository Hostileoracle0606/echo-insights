import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_output.dart';
import '../audio/audio_session_config.dart';
import '../services/live_credentials.dart';
import 'auth_provider.dart';
import 'supabase_provider.dart';

/// App-level voice services: they live for the signed-in user, not for a
/// notebook (plan: Phase 1). [VoiceServicesBinding] starts and stops them.
final liveCredentialsProvider = Provider<LiveCredentials>((ref) {
  final runtime = ref.watch(notebookRuntimeServiceProvider);
  final credentials = LiveCredentials(fetch: runtime.startUserLiveSession);
  ref.onDispose(credentials.stop);
  return credentials;
});

final audioOutputProvider = Provider<AudioOutput>((ref) {
  final output = AudioOutput(prepare: configureVoiceAudioSession);
  ref.onDispose(output.stop);
  return output;
});

/// Follows sign-in and the app lifecycle for the app-level voice services.
class VoiceServicesBinding {
  VoiceServicesBinding({
    required this.credentials,
    required this.audioOutput,
    this.runtimeConfigured = true,
  });

  final LiveCredentials credentials;
  final AudioOutput audioOutput;

  /// Without a runtime URL there is nothing to fetch tokens from.
  final bool runtimeConfigured;
  bool _signedIn = false;

  void signedInChanged(bool signedIn) {
    if (signedIn == _signedIn) return;
    _signedIn = signedIn;
    if (signedIn) {
      if (runtimeConfigured) credentials.start();
      audioOutput.start();
    } else {
      credentials.stop();
      audioOutput.stop();
    }
  }

  void lifecycleChanged(AppLifecycleState lifecycle) {
    if (!_signedIn) return;
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        credentials.resume();
        // A start that failed earlier (or never ran) gets another chance.
        audioOutput.start();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        credentials.pause();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}

/// Wraps the app so the voice services follow auth state and lifecycle.
class VoiceServicesScope extends ConsumerStatefulWidget {
  const VoiceServicesScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<VoiceServicesScope> createState() => _VoiceServicesScopeState();
}

class _VoiceServicesScopeState extends ConsumerState<VoiceServicesScope>
    with WidgetsBindingObserver {
  // Built on the first sign-in: the services need a configured Supabase
  // client, which a signed-out (or unconfigured) app may not have.
  VoiceServicesBinding? _binding;

  void _signedInChanged(bool signedIn) {
    if (!signedIn && _binding == null) return;
    (_binding ??= VoiceServicesBinding(
      credentials: ref.read(liveCredentialsProvider),
      audioOutput: ref.read(audioOutputProvider),
      runtimeConfigured: ref.read(notebookRuntimeServiceProvider).isConfigured,
    ))
        .signedInChanged(signedIn);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _signedInChanged(ref.read(authProvider).valueOrNull != null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    _binding?.lifecycleChanged(lifecycle);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authProvider, (_, next) {
      _signedInChanged(next.valueOrNull != null);
    });
    return widget.child;
  }
}

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_output.dart';
import '../services/live_credentials.dart';
import 'auth_provider.dart';
import 'journal_provider.dart' show turnJournalServiceProvider;
import 'opening_prep_provider.dart';
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
  // The player's backend prepares the native engine (session included).
  final output = AudioOutput();
  ref.onDispose(output.stop);
  return output;
});

/// Follows sign-in and the app lifecycle for the app-level voice services.
class VoiceServicesBinding {
  VoiceServicesBinding({
    required this.credentials,
    required this.audioOutput,
    this.runtimeConfigured = true,
    this.warmUp,
    this.onResume,
    this.onSignedOut,
  });

  final LiveCredentials credentials;
  final AudioOutput audioOutput;

  /// Readies what the first notebook open reads, so it isn't paid between
  /// tapping New notebook and Lumen's greeting.
  final Future<void> Function()? warmUp;

  /// Runs when the app returns to the foreground (signed in): refreshes the
  /// session brief.
  final Future<void> Function()? onResume;

  /// Runs on sign-out: drops per-account state held for the opening.
  final void Function()? onSignedOut;

  /// Without a runtime URL there is nothing to fetch tokens from.
  final bool runtimeConfigured;
  bool _signedIn = false;

  void signedInChanged(bool signedIn) {
    if (signedIn == _signedIn) return;
    _signedIn = signedIn;
    if (signedIn) {
      if (runtimeConfigured) credentials.start();
      audioOutput.start();
      warmUp?.call();
    } else {
      credentials.stop();
      audioOutput.stop();
      onSignedOut?.call();
    }
  }

  void lifecycleChanged(AppLifecycleState lifecycle) {
    if (!_signedIn) return;
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        credentials.resume();
        // A start that failed earlier (or never ran) gets another chance.
        audioOutput.start();
        onResume?.call();
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
    if (_binding == null) {
      final journal = ref.read(turnJournalServiceProvider);
      final openingPrep = ref.read(openingPrepProvider);
      _binding = VoiceServicesBinding(
        credentials: ref.read(liveCredentialsProvider),
        audioOutput: ref.read(audioOutputProvider),
        runtimeConfigured:
            ref.read(notebookRuntimeServiceProvider).isConfigured,
        // Both are best-effort and independent; neither blocks a session.
        warmUp: () => Future.wait([journal.warmUp(), openingPrep.refresh()]),
        // Coming back also re-asks for a brief that failed earlier.
        onResume: () => Future.wait(
            [openingPrep.refresh(), openingPrep.retryPendingBrief()]),
        onSignedOut: openingPrep.clear,
      );
    }
    _binding!.signedInChanged(signedIn);
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
    // Any touch means someone is here: keep the held token fresh (refreshes
    // stop after a stretch without activity).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _binding?.credentials.noteActivity(),
      child: widget.child,
    );
  }
}

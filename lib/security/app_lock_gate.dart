import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';
import 'app_lock.dart';
import 'app_lock_provider.dart';

/// Wraps the app: while the lock is on and not yet passed, a lock screen
/// covers everything and the app beneath is taken out of paint, hit-testing
/// and semantics. Feeds the lock the app's lifecycle.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  // One automatic Face ID prompt per time the lock closes; after a cancel the
  // person taps Unlock.
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    ref.read(appLockProvider).lifecycleChanged(lifecycle);
    if (lifecycle == AppLifecycleState.resumed) {
      // Scheduled after the lock has had its say on this resume.
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptIfLocked());
    }
  }

  void _promptIfLocked() {
    if (!mounted) return;
    final lock = ref.read(appLockProvider);
    if (lock.status != AppLockStatus.locked || _prompted) return;
    _prompted = true;
    lock.unlock();
  }

  @override
  Widget build(BuildContext context) {
    final lock = ref.watch(appLockProvider);
    final covered = lock.status != AppLockStatus.unlocked;
    if (lock.status == AppLockStatus.locked) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptIfLocked());
    } else {
      _prompted = false;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: covered, child: widget.child),
        if (covered)
          LockScreen(
            loading: lock.status == AppLockStatus.loading,
            busy: lock.authenticating,
            onUnlock: lock.unlock,
          ),
      ],
    );
  }
}

class LockScreen extends StatelessWidget {
  const LockScreen({
    super.key,
    required this.onUnlock,
    this.loading = false,
    this.busy = false,
  });

  final Future<bool> Function() onUnlock;
  final bool loading;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Scaffold(
      key: const Key('lockScreen'),
      backgroundColor: colors.paper,
      body: Center(
        child: loading
            ? const SizedBox.shrink()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 34, color: colors.ink),
                  const SizedBox(height: 16),
                  Text(
                    'Lumen is locked',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontSize: 22),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    key: const Key('unlockButton'),
                    onPressed: busy ? null : () => onUnlock(),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.ink,
                      foregroundColor: colors.paper,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      textStyle: const TextStyle(
                        fontFamily: LumenText.sansFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    child: const Text('Unlock'),
                  ),
                ],
              ),
      ),
    );
  }
}

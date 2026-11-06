import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/quiet_mode_provider.dart';
import '../../security/app_lock_provider.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// The dashboard's shield button: opens [PrivacySheet].
class PrivacyButton extends StatelessWidget {
  const PrivacyButton({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return IconButton(
      key: const Key('privacyButton'),
      tooltip: 'Privacy',
      icon: Icon(Icons.shield_outlined, color: colors.ink),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: colors.paper,
        showDragHandle: true,
        builder: (_) => const PrivacySheet(),
      ),
    );
  }
}

/// App lock and quiet mode. Self-contained: it reads and writes only
/// [appLockProvider] and [quietModeProvider].
class PrivacySheet extends ConsumerStatefulWidget {
  const PrivacySheet({super.key});

  @override
  ConsumerState<PrivacySheet> createState() => _PrivacySheetState();
}

class _PrivacySheetState extends ConsumerState<PrivacySheet> {
  String? _problem;

  Future<void> _setLock(bool on) async {
    final lock = ref.read(appLockProvider);
    setState(() => _problem = null);
    final done = on ? await lock.enable() : await lock.disable();
    if (!mounted || done) return;
    setState(() =>
        _problem = on ? 'Set a passcode on this phone to use app lock.' : null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final lock = ref.watch(appLockProvider);
    final quiet = ref.watch(quietModeProvider);
    final small = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 13,
      height: 1.4,
      color: colors.mutedForeground,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              key: const Key('appLockSwitch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('App lock'),
              subtitle: Text(
                'Ask for Face ID or your passcode when Lumen opens and after '
                'it has been in the background for 5 minutes.',
                style: small,
              ),
              value: lock.enabled,
              onChanged: lock.authenticating ? null : _setLock,
            ),
            if (_problem != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_problem!,
                    style: small.copyWith(color: colors.destructive)),
              ),
            SwitchListTile(
              key: const Key('quietModeSwitch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Quiet mode'),
              subtitle: Text(
                'Lumen speaks only through headphones or Bluetooth. '
                'Otherwise you read the words on screen.',
                style: small,
              ),
              value: quiet,
              onChanged: (on) => ref.read(quietModeProvider.notifier).set(on),
            ),
          ],
        ),
      ),
    );
  }
}

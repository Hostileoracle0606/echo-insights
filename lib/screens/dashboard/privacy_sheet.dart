import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/export_provider.dart';
import '../../providers/quiet_mode_provider.dart';
import '../../security/app_lock_provider.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../widgets/transcript_retention.dart';
import '../privacy/who_hears_you_screen.dart';

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
        // Taller than the default half screen once transcripts open.
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const PrivacySheet(),
      ),
    );
  }
}

/// App lock, quiet mode, how long transcripts are kept, and "Export my
/// journal": every privacy setting, in one place. Self-contained: it reads
/// and writes only [appLockProvider] and [quietModeProvider], and exports
/// through [journalExportServiceProvider] and [shareVaultProvider];
/// [TranscriptRetentionChoices] handles its own setting.
class PrivacySheet extends ConsumerStatefulWidget {
  const PrivacySheet({super.key});

  @override
  ConsumerState<PrivacySheet> createState() => _PrivacySheetState();
}

class _PrivacySheetState extends ConsumerState<PrivacySheet> {
  String? _problem;
  bool _exporting = false;
  String? _exportStatus;
  bool _exportFailed = false;

  Future<void> _export() async {
    // Anyone holding an unlocked phone could otherwise copy the whole journal.
    // A failed or cancelled check shares nothing.
    if (!await requireReauth(context, reason: 'Export your journal')) return;
    if (!mounted) return;
    setState(() {
      _exporting = true;
      _exportFailed = false;
      _exportStatus = 'Collecting your journal…';
    });
    final service = ref.read(journalExportServiceProvider);
    final share = ref.read(shareVaultProvider);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    try {
      final export = await service.fetch(
        onProgress: (done, total) {
          if (mounted && total > 0) {
            setState(
              () => _exportStatus =
                  'Collecting your journal: '
                  '$done of $total notebooks…',
            );
          }
        },
      );
      if (mounted) setState(() => _exportStatus = 'Building the file…');
      final vault = await service.build(export);
      await share(vault, origin: origin);
    } catch (error) {
      // The type only: a parse or server error can quote the journal.
      debugPrint('Journal export failed: ${error.runtimeType}');
      if (mounted) setState(() => _exportFailed = true);
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _exportStatus = null;
        });
      }
    }
  }

  Future<void> _setLock(bool on) async {
    final lock = ref.read(appLockProvider);
    setState(() => _problem = null);
    final done = on ? await lock.enable() : await lock.disable();
    if (!mounted || done) return;
    setState(
      () => _problem = on
          ? 'Set a passcode on this phone to use app lock.'
          : null,
    );
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
      child: SingleChildScrollView(
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
                child: Text(
                  _problem!,
                  style: small.copyWith(color: colors.destructive),
                ),
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
            ExpansionTile(
              key: const Key('transcriptRetentionTile'),
              tilePadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              iconColor: colors.ink,
              collapsedIconColor: colors.ink,
              title: const Text('Keep transcripts for…'),
              subtitle: Text(
                'Cards and what Lumen remembers stay.',
                style: small,
              ),
              children: const [TranscriptRetentionChoices()],
            ),
            ListTile(
              key: const Key('exportJournalTile'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Export my journal'),
              subtitle: Text(
                _exportFailed
                    ? 'The export did not finish. Check your connection and '
                          'try again.'
                    : _exportStatus ??
                          'A zip with your whole journal as data and as '
                              'Markdown notes. Asks for Face ID first.',
                style: _exportFailed
                    ? small.copyWith(color: colors.destructive)
                    : small,
              ),
              trailing: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(Icons.ios_share, color: colors.ink),
              onTap: _exporting ? null : _export,
            ),
            ListTile(
              key: const Key('whoHearsYouTile'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Who hears you'),
              subtitle: Text(
                'Who sees what of your journal, in plain words.',
                style: small,
              ),
              trailing: Icon(Icons.chevron_right, color: colors.ink),
              onTap: () => showWhoHearsYou(context),
            ),
          ],
        ),
      ),
    );
  }
}

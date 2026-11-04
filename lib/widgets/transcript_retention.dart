import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/retention_offer.dart';
import '../providers/supabase_provider.dart';
import '../services/transcript_retention_service.dart';
import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';

/// Where the one-time offer is remembered. Overridable in tests.
final retentionPrefsProvider = Provider<Future<SharedPreferences>>(
  (ref) => SharedPreferences.getInstance(),
);

String retentionLabel(int? days) => days == null ? 'Forever' : '$days days';

/// "Keep transcripts for…" (LM-51): the choice sheet, used from the
/// dashboard's settings button and for the one-time offer.
Future<void> showTranscriptRetentionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.lumenColors.paper,
    builder: (_) => const TranscriptRetentionSheet(),
  );
}

/// Shows the sheet once, after [retentionOfferAfterSessions] finished
/// sessions. "Offered" is remembered on this device the moment it is shown,
/// so dismissing it does not bring it back. Unreadable prefs mean no offer.
Future<void> offerRetentionIfDue(
  BuildContext context,
  WidgetRef ref, {
  required int completedSessions,
}) async {
  if (completedSessions < retentionOfferAfterSessions) return;
  SharedPreferences prefs;
  try {
    prefs = await ref.read(retentionPrefsProvider);
  } catch (_) {
    return;
  }
  final offered = prefs.getBool(retentionOfferedKey) ?? false;
  if (!shouldOfferRetention(
    completedSessions: completedSessions,
    alreadyOffered: offered,
  )) {
    return;
  }
  if (!context.mounted) return;
  await prefs.setBool(retentionOfferedKey, true);
  if (!context.mounted) return;
  await showTranscriptRetentionSheet(context);
}

class TranscriptRetentionSheet extends ConsumerStatefulWidget {
  const TranscriptRetentionSheet({super.key});

  @override
  ConsumerState<TranscriptRetentionSheet> createState() =>
      _TranscriptRetentionSheetState();
}

class _TranscriptRetentionSheetState
    extends ConsumerState<TranscriptRetentionSheet> {
  bool _loaded = false;
  bool _saving = false;
  bool _failed = false;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final days = await ref.read(transcriptRetentionServiceProvider).current();
      if (!mounted) return;
      setState(() {
        _selected = days;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loaded = true;
      });
    }
  }

  Future<void> _choose(int? days) async {
    if (_saving || (_loaded && !_failed && days == _selected)) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await ref.read(transcriptRetentionServiceProvider).set(days);
      if (!mounted) return;
      setState(() {
        _selected = days;
        _saving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Keep transcripts for…',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 8),
            Text(
              'Cards and what Lumen remembers stay.',
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 14,
                height: 1.45,
                color: colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 12),
            for (final days in transcriptRetentionChoices)
              _Option(
                days: days,
                selected: _loaded && !_failed && days == _selected,
                enabled: _loaded && !_saving,
                onTap: () => _choose(days),
                colors: colors,
              ),
            if (_failed) ...[
              const SizedBox(height: 8),
              Text(
                "Couldn't save that. Try again.",
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 13,
                  color: colors.destructive,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(44, 44)),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.days,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.colors,
  });

  final int? days;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final LumenColors colors;

  @override
  Widget build(BuildContext context) {
    final label = retentionLabel(days);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        key: Key('retention-${days ?? 'forever'}'),
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: LumenText.sansFontFamily,
                    fontSize: 16,
                    color: colors.ink,
                  ),
                ),
              ),
              if (selected) Icon(Icons.check, size: 20, color: colors.amber),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sits in the dashboard and offers the choice once, when due.
class RetentionOffer extends ConsumerStatefulWidget {
  const RetentionOffer({super.key, required this.completedSessions});

  final int completedSessions;

  @override
  ConsumerState<RetentionOffer> createState() => _RetentionOfferState();
}

class _RetentionOfferState extends ConsumerState<RetentionOffer> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _checked) return;
      _checked = true;
      offerRetentionIfDue(
        context,
        ref,
        completedSessions: widget.completedSessions,
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

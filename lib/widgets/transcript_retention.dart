import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/retention_offer.dart';
import '../providers/supabase_provider.dart';
import '../security/app_lock_provider.dart';
import '../services/transcript_retention_service.dart';
import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';

String retentionLabel(int? days) => days == null ? 'Forever' : '$days days';

/// "Keep transcripts for…" (LM-51): the sheet for the one-time offer. The
/// same choices sit in the privacy sheet ([TranscriptRetentionChoices]).
Future<void> showTranscriptRetentionSheet(
  BuildContext context, {
  bool markOffered = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.lumenColors.paper,
    builder: (_) => TranscriptRetentionSheet(markOffered: markOffered),
  );
}

/// Shows the sheet once per account, after [retentionOfferAfterSessions]
/// finished sessions. The sheet records the offer on the profile once it is
/// on screen, so dismissing it, a reinstall or a second device do not bring
/// it back. If the profile can't be read, nothing is offered.
Future<void> offerRetentionIfDue(
  BuildContext context,
  WidgetRef ref, {
  required int completedSessions,
}) async {
  if (completedSessions < retentionOfferAfterSessions) return;
  bool offered;
  try {
    offered = await ref.read(transcriptRetentionServiceProvider).wasOffered();
  } catch (_) {
    return;
  }
  if (!shouldOfferRetention(
    completedSessions: completedSessions,
    alreadyOffered: offered,
  )) {
    return;
  }
  if (!context.mounted) return;
  await showTranscriptRetentionSheet(context, markOffered: true);
}

class TranscriptRetentionSheet extends ConsumerStatefulWidget {
  const TranscriptRetentionSheet({super.key, this.markOffered = false});

  /// Record on the profile that this sheet was shown (the one-time offer).
  final bool markOffered;

  @override
  ConsumerState<TranscriptRetentionSheet> createState() =>
      _TranscriptRetentionSheetState();
}

class _TranscriptRetentionSheetState
    extends ConsumerState<TranscriptRetentionSheet> {
  @override
  void initState() {
    super.initState();
    if (widget.markOffered) {
      // After the sheet has been built and is on screen.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await ref.read(transcriptRetentionServiceProvider).markOffered();
        } catch (_) {
          // Offered again next time, which is the safe direction.
        }
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
            const TranscriptRetentionChoices(),
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

/// Forever / 90 / 30 / 7 days: reads the current setting and saves a choice.
class TranscriptRetentionChoices extends ConsumerStatefulWidget {
  const TranscriptRetentionChoices({super.key});

  @override
  ConsumerState<TranscriptRetentionChoices> createState() =>
      _TranscriptRetentionChoicesState();
}

class _TranscriptRetentionChoicesState
    extends ConsumerState<TranscriptRetentionChoices> {
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

  /// A shorter period deletes what is older at the next sweep, for good. An
  /// unknown current setting counts as shorter.
  Future<bool> _shortenAllowed(int days) async {
    final current = _failed ? 0 : _selected;
    if (current != null && current != 0 && days >= current) return true;
    final colors = context.lumenColors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Keep transcripts for $days days?'),
        content: Text(
          'Transcripts older than $days days are deleted at the next daily '
          "clean-up. You can't undo this. Cards and what Lumen remembers stay.",
        ),
        actions: [
          TextButton(
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(44, 44)),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(44, 44),
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Keep for less'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    return requireReauth(context, reason: 'Delete older transcripts');
  }

  Future<void> _choose(int? days) async {
    if (_saving || (_loaded && !_failed && days == _selected)) return;
    if (days != null && !await _shortenAllowed(days)) return;
    if (!mounted) return;
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      ],
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/catch_up_provider.dart';
import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';

/// Shown while launch-time catch-up (LM-103) is still making a notebook's
/// card. Calm on purpose: the work is in hand, nothing is wrong.
const finishingUpCopy = 'Finishing up…';

/// One muted line under a notebook row while its card is pending; nothing
/// otherwise.
class FinishingUpNote extends ConsumerWidget {
  const FinishingUpNote({super.key, required this.notebookId});

  final String notebookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(
      catchUpProvider.select((state) => state.isCardPending(notebookId)),
    );
    if (!pending) return const SizedBox.shrink();
    final colors = context.lumenColors;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        finishingUpCopy,
        style: TextStyle(
          fontFamily: LumenText.sansFontFamily,
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: colors.mutedForeground,
        ),
      ),
    );
  }
}

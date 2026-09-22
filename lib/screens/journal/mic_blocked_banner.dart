import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// Shown while microphone access is permanently denied. iOS asks only once,
/// so after "Don't Allow" the only way back is Settings; this stays on screen
/// (unlike a SnackBar) until access is granted.
class MicBlockedBanner extends StatelessWidget {
  const MicBlockedBanner({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Material(
      color: colors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.mic_off, size: 18, color: colors.destructive),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Microphone access is off',
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Lumen needs the microphone to hear your journal. '
                'Turn on Microphone for Lumen in Settings.',
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 13,
                  height: 1.4,
                  color: colors.mutedForeground,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onOpenSettings,
                style: TextButton.styleFrom(foregroundColor: colors.amber),
                child: const Text('Open Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

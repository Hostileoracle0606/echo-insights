import 'package:flutter/material.dart';

import '../theme/lumen_colors.dart';
import '../theme/lumen_text.dart';

/// The tiny uppercase section label ("THIS WEEK · 3 WINS"). Takes normal-case
/// text, shows it uppercase, and hands screen readers the normal-case text —
/// VoiceOver can spell an all-caps string out letter by letter.
class Eyebrow extends StatelessWidget {
  final String text;

  /// Defaults to mutedForeground. Use youLabel/lumenLabel for "You"/"Lumen"
  /// labels; never sage or amber (too faint for 10pt text).
  final Color? color;

  const Eyebrow(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Text(
        text.toUpperCase(),
        style: LumenText.eyebrow(color ?? context.lumenColors.mutedForeground),
      ),
    );
  }
}

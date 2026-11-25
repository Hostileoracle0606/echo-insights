import 'package:flutter/material.dart';
import 'package:lumen/theme/lumen_colors.dart';

/// A small "BETA" tag for a control that works but is still being tested.
/// Decorative: callers put "beta" in their own semantics label.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'BETA',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

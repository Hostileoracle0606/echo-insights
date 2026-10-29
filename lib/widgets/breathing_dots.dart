import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three dots that brighten in turn, slow and quiet: Lumen is mulling over
/// a reply. Shared by the pill's status line and the transcript's waiting
/// row. With reduced motion they hold still.
class BreathingDots extends StatefulWidget {
  final Color color;
  final double size;

  const BreathingDots({super.key, required this.color, this.size = 4});

  @override
  State<BreathingDots> createState() => _BreathingDotsState();
}

class _BreathingDotsState extends State<BreathingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _breath.stop();
    } else if (!_breath.isAnimating) {
      _breath.repeat();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _breath,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: widget.size * 0.9),
              Opacity(
                opacity: still ? 0.6 : _opacity(i),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // Each dot peaks a third of a cycle after the one before it.
  double _opacity(int i) {
    final phase = (_breath.value - i / 3) % 1;
    return 0.25 + 0.75 * (0.5 + 0.5 * math.cos(2 * math.pi * phase));
  }
}

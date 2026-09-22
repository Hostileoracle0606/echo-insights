import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_theme.dart';

/// Floating transcript bubble (paper theme): fades in for ~4s when the live
/// transcript changes. Rethemed from the old dark overlay onto the tokens.
class TranscriptOverlay extends StatefulWidget {
  final String text;

  const TranscriptOverlay({super.key, required this.text});

  @override
  State<TranscriptOverlay> createState() => _TranscriptOverlayState();
}

class _TranscriptOverlayState extends State<TranscriptOverlay> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Show on mount if text is already present (the app mounts empty and text
    // arrives later, but this keeps a text-present mount from staying hidden).
    if (widget.text.trim().isNotEmpty) _show();
  }

  @override
  void didUpdateWidget(covariant TranscriptOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text && widget.text.trim().isNotEmpty) {
      _show();
    }
  }

  void _show() {
    _timer?.cancel();
    _visible = true;
    _timer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible && widget.text.trim().isNotEmpty ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
            boxShadow: surface.shadowPaper,
          ),
          child: Text(
            widget.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.ink),
          ),
        ),
      ),
    );
  }
}

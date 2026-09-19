import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';

/// Dock state — drives chrome + the living silhouette. Mapped from SessionStatus
/// at the call site.
enum DockMode { idle, listening, speaking, thinking }

/// Who spoke a turn in the split-screen transcript.
enum DockSpeaker { you, lumen }

/// One line of the rolling conversation. The journal provider keeps canonical
/// user/assistant roles; the screen maps them to these presentation labels.
class DockTurn {
  final DockSpeaker speaker;
  final String text;
  const DockTurn(this.speaker, this.text);
}

/// The bottom voice capsule. Two orthogonal axes of state:
///
///  * [mode] — the *voice* state. idle/thinking paint a static paper pill;
///    listening/speaking paint the living mercury-goo silhouette behind the
///    controls (blur + alpha-threshold, the CSS goo filter's equivalent).
///  * [expanded] — the *split-screen* state. When true the capsule morphs,
///    Dynamic-Island style, into a tall panel: a ChatGPT-style transcript of
///    [turns] scrolls above the control row, which stays pinned to the bottom
///    on the same paper surface. The morph is bottom-anchored growth — the
///    parent keeps the dock in `Align(bottomCenter)`, so the bottom edge holds
///    still and the panel climbs upward while the buttons never move.
///
/// The split toggle that flips [expanded] sits in the control row (where the
/// keyboard button used to be); it reflects [expanded] and reports taps via
/// [onToggleSplit], so the parent still owns the shared flag.
class VoiceDock extends StatefulWidget {
  final DockMode mode;
  final String? transcript;
  final bool muted;
  final bool expanded;
  final List<DockTurn> turns;
  final VoidCallback onMicTap;
  final VoidCallback? onToggleSplit;
  final VoidCallback? onMuteTap;

  const VoiceDock({
    super.key,
    this.mode = DockMode.idle,
    this.transcript,
    this.muted = false,
    this.expanded = false,
    this.turns = const [],
    required this.onMicTap,
    this.onToggleSplit,
    this.onMuteTap,
  });

  @override
  State<VoiceDock> createState() => _VoiceDockState();
}

class _VoiceDockState extends State<VoiceDock> with TickerProviderStateMixin {
  // The silhouette drift + the mic pulse share one repeating clock.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  // The split morph, matching the web dock's spring: 500ms with
  // cubic-bezier(.34, 1.56, .64, 1) both directions — a soft overshoot on
  // open ("bounce"), a soft squish on close. Width clamps at its target so
  // only height carries the overshoot (see _expandedDock).
  static const Curve _spring = Cubic(0.34, 1.56, 0.64, 1);
  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );
  late final Animation<double> _e = CurvedAnimation(
    parent: _expand,
    curve: _spring,
    reverseCurve: _spring,
  );

  // Panel-content opacity, on the web's transition timing: fade IN over the
  // back 60% of the open (delay 200 / duration 300 of the 500ms morph), fade
  // OUT within the first ~100ms of the close.
  late final Animation<double> _fade = CurvedAnimation(
    parent: _expand,
    curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
    reverseCurve: const Interval(0.8, 1.0, curve: Curves.easeIn),
  );

  final ScrollController _scroll = ScrollController();

  // Collapsed footprint == the intrinsic pill: padding(6) + side(44) + mic(48)
  // + side(44). The morph lerps from here so the first frame matches the pill.
  static const double _collapsedW = 148;
  static const double _collapsedH = 60;

  bool get _voiceActive =>
      widget.mode == DockMode.listening || widget.mode == DockMode.speaking;

  // Anything that should keep the shared _pulse clock ticking — voice-active
  // (goo + mic ring) plus thinking (dim mic breathe, see _mic).
  bool get _pulseActive => _voiceActive || widget.mode == DockMode.thinking;

  @override
  void initState() {
    super.initState();
    if (_pulseActive) _pulse.repeat();
    if (widget.expanded) {
      _expand.value = 1;
      _jumpToBottomSoon();
    }
  }

  @override
  void didUpdateWidget(covariant VoiceDock old) {
    super.didUpdateWidget(old);
    if (_pulseActive && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!_pulseActive && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..reset();
    }
    if (widget.expanded && !old.expanded) {
      _expand.forward();
      _jumpToBottomSoon();
    } else if (!widget.expanded && old.expanded) {
      _expand.reverse();
    } else if (widget.expanded && widget.turns.length != old.turns.length) {
      _jumpToBottomSoon();
    }
  }

  void _jumpToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _expand.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;

    // Rebuild scoping (the web version is GPU-composited CSS; this is the
    // Flutter equivalent): the morph AnimatedBuilder listens ONLY to _expand
    // and animates just the frame — the panel content is prebuilt once per
    // widget build and passed through as `child`. The _pulse clock rebuilds no
    // widgets at all: the goo painter and the mic ring each listen to it
    // directly. RepaintBoundary keeps the dock's 60fps repaints off the rest
    // of the screen.
    final screen = MediaQuery.sizeOf(context);
    final expandedW = (screen.width - 32).clamp(280.0, 560.0);
    final maxBubble = (expandedW - 36) * 0.82;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _expand,
        child: _expandedContent(colors, maxBubble),
        builder: (context, child) {
          // Value-based branch (not status-based): on the tap frame the
          // controller is `forward` at value 0 — rendering the panel at its
          // 60px start would overflow the pinned buttons for that one frame.
          // At e ≤ 0 (rest, and the spring's squish tail on close) show the
          // pill; the first real morph frame is already tall enough.
          if (_e.value <= 0) return _restDock(colors, surface);
          // Morphing or open: the paper panel, sized by the spring.
          return _expandedDock(context, colors, surface, child!);
        },
      ),
    );
  }

  // ----- collapsed (rest) ---------------------------------------------------

  Widget _restDock(LumenColors colors, LumenSurface surface) {
    final buttons = _buttons(colors, padding: const EdgeInsets.all(6));
    if (!_voiceActive) {
      return Container(
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: colors.border),
          boxShadow: surface.shadowPaper,
        ),
        child: buttons,
      );
    }
    // Living silhouette paints the capsule itself; controls ride on top. The
    // painter listens to the pulse clock directly (repaint:), so its 60fps
    // drift repaints without rebuilding any widgets.
    return CustomPaint(
      painter: _GooPainter(
        pulse: _pulse,
        fill: colors.card,
        rim: colors.border,
        shadow: colors.ink.withValues(alpha: 0.10),
      ),
      child: buttons,
    );
  }

  // ----- expanded (split-screen panel) --------------------------------------

  Widget _expandedDock(
    BuildContext context,
    LumenColors colors,
    LumenSurface surface,
    Widget child,
  ) {
    final screen = MediaQuery.sizeOf(context);
    final expandedW = (screen.width - 32).clamp(280.0, 560.0);
    final expandedH = (screen.height * 0.62).clamp(360.0, 720.0);
    final e = _e.value;
    // The spring overshoots past 1. Height carries the bounce (the island
    // springs upward past its resting size, like the web); width and radius
    // clamp at their targets so the panel never spills past the screen's side
    // margins mid-bounce.
    final eh = e < 0 ? 0.0 : e;
    final ew = e.clamp(0.0, 1.0);
    final w = lerpDouble(_collapsedW, expandedW, ew)!;
    final h = lerpDouble(_collapsedH, expandedH, eh)!;
    final radius = lerpDouble(32, 30, ew)!;

    return Container(
      width: w,
      height: h,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.border),
        boxShadow: surface.shadowPaper,
      ),
      child: child,
    );
  }

  // The expanded panel's content, prebuilt once per widget build so the
  // per-frame morph never rebuilds it. Its fade rides [_fade] on the web's
  // delayed-in / instant-out timing via a self-listening FadeTransition.
  Widget _expandedContent(LumenColors colors, double maxBubble) {
    return Column(
      children: [
        Expanded(
          child: FadeTransition(
            opacity: _fade,
            child: _conversation(colors, maxBubble),
          ),
        ),
        // Uniform padding sets the controls apart from the rolling
        // conversation, on the one shared paper surface.
        _buttons(colors, padding: const EdgeInsets.symmetric(vertical: 14)),
      ],
    );
  }

  Widget _conversation(LumenColors colors, double maxBubble) {
    final rows = <Widget>[
      for (final turn in widget.turns)
        _bubble(colors, turn.speaker, turn.text, maxBubble),
    ];
    // The in-flight partial transcript rides at the bottom as a pending bubble,
    // so the panel feels live mid-sentence.
    final live = widget.transcript?.trim() ?? '';
    final alreadyShown = widget.turns.isNotEmpty && widget.turns.last.text == live;
    if (_voiceActive && live.isNotEmpty && !alreadyShown) {
      rows.add(_bubble(colors, DockSpeaker.you, live, maxBubble, pending: true));
    }

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 6),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => rows[i],
    );
  }

  Widget _bubble(
    LumenColors colors,
    DockSpeaker speaker,
    String text,
    double maxBubble, {
    bool pending = false,
  }) {
    final you = speaker == DockSpeaker.you;
    return Align(
      alignment: you ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxBubble),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: you ? colors.amberSoft : colors.muted,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(you ? 16 : 5),
              bottomRight: Radius.circular(you ? 5 : 16),
            ),
          ),
          child: Opacity(
            opacity: pending ? 0.6 : 1,
            child: Text(
              text,
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 13.5,
                height: 1.45,
                // Warm brown on amberSoft reads softer than ink; ink on muted.
                color: you ? const Color(0xFF5A3A12) : colors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ----- shared control cluster ---------------------------------------------

  Widget _buttons(LumenColors colors, {required EdgeInsets padding}) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _SplitControl(
            active: widget.expanded,
            onTap: widget.onToggleSplit,
            colors: colors,
          ),
          _mic(colors),
          _SideControl(
            icon: widget.muted ? Icons.volume_off : Icons.volume_up,
            color: colors.mutedForeground,
            onTap: widget.onMuteTap,
          ),
        ],
      ),
    );
  }

  Widget _mic(LumenColors colors) {
    final listening = widget.mode == DockMode.listening;
    final thinking = widget.mode == DockMode.thinking;
    // Scoped to its own AnimatedBuilder: the pulse animates only this 48×48
    // subtree (ring + fill), never the rest of the dock.
    return SizedBox(
      width: 48,
      height: 48,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = _pulse.value;
          // Thinking dims/brightens the mic's own fill in one slow, quiet
          // breath per pulse cycle (never reaching full brightness) —
          // "booting up," not "recording" (that's the amber ring) and not
          // "talking" (the goo).
          final thinkingBreath = 0.55 + 0.20 * (0.5 + 0.5 * math.sin(math.pi * t));
          return Stack(
            alignment: Alignment.center,
            children: [
              if (listening)
                // Expanding amber pulse ring — the "recording" signal.
                Opacity(
                  opacity: (1 - t) * 0.5,
                  child: Transform.scale(
                    scale: 1 + t * 0.5,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.amber, width: 2),
                      ),
                    ),
                  ),
                ),
              GestureDetector(
                onTap: widget.onMicTap,
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: thinking
                        ? colors.amber.withValues(alpha: thinkingBreath)
                        : colors.amber,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic, size: 18, color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SideControl extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _SideControl({required this.icon, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

/// The split-screen toggle in the dock's control row (replacing the keyboard
/// button). It fills with ink while the transcript panel is open, mirroring the
/// [VoiceDock.expanded] state; the 44px box keeps a thumb-friendly hit target.
class _SplitControl extends StatelessWidget {
  final bool active;
  final VoidCallback? onTap;
  final LumenColors colors;

  const _SplitControl({
    required this.active,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? colors.ink : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.splitscreen,
              size: 18,
              color: active ? colors.paper : colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the living mercury silhouette: a card-colored metaball (capsule +
/// drifting blobs) fused by blur + an alpha-threshold colour matrix — the
/// Flutter equivalent of the web's SVG goo filter. A slightly-larger rim pass
/// in the border colour gives the fused edge definition on paper; a soft
/// drop-shadow lifts it.
class _GooPainter extends CustomPainter {
  // Listening directly to the pulse clock (super.repaint) lets the silhouette
  // drift at 60fps with zero widget rebuilds.
  final Animation<double> pulse;
  final Color fill;
  final Color rim;
  final Color shadow;

  _GooPainter({
    required this.pulse,
    required this.fill,
    required this.rim,
    required this.shadow,
  }) : super(repaint: pulse);

  double get t => pulse.value;

  static const double _radius = 32;
  static const double _tau = 2 * math.pi;

  // Alpha-threshold matrix: A' = 24·A − 3500 (clamped). Blurred overlaps below
  // ~57% coverage are cut, above are kept solid — fusing the shapes into goo.
  static const ColorFilter _threshold = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 24, -3500,
  ]);

  List<({Offset c, double r})> _blobs(Size size, double inflate) {
    double px(double f) => f * size.width;
    double pulse(double phase) => 0.5 + 0.5 * math.sin(_tau * t + phase);
    return [
      (c: Offset(px(0.24), 2 - pulse(0.0) * 4), r: 7 + inflate + pulse(0.0) * 4),
      (c: Offset(px(0.70), 2 - pulse(1.2) * 5), r: 6 + inflate + pulse(1.2) * 4),
      (c: Offset(px(0.34), size.height - 2 + pulse(2.1) * 4), r: 7 + inflate + pulse(2.1) * 4),
      (c: Offset(px(0.78), size.height - 2 + pulse(3.0) * 5), r: 6 + inflate + pulse(3.0) * 4),
    ];
  }

  void _metaball(Canvas canvas, Size size, Color color, double inflate) {
    final bounds = (Offset.zero & size).inflate(24);
    canvas.saveLayer(bounds, Paint()..colorFilter = _threshold);
    final paint = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).inflate(inflate),
        Radius.circular(_radius + inflate),
      ),
      paint,
    );
    for (final b in _blobs(size, inflate)) {
      canvas.drawCircle(b.c, b.r, paint);
    }
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Soft lift.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).shift(const Offset(0, 8)),
        const Radius.circular(_radius),
      ),
      Paint()
        ..color = shadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    _metaball(canvas, size, rim, 1.5); // border rim
    _metaball(canvas, size, fill, 0.0); // card fill on top
  }

  @override
  bool shouldRepaint(covariant _GooPainter old) =>
      old.pulse != pulse || old.fill != fill || old.rim != rim;
}

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../models/upsert_activity.dart';
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

  /// Still being transcribed — drawn faded, in its spoken slot.
  final bool pending;
  const DockTurn(this.speaker, this.text, {this.pending = false});
}

/// The bottom voice capsule. Two orthogonal axes of state:
///
///  * [mode] — the *voice* state. idle/thinking paint a static paper pill;
///    listening/speaking paint the living mercury-goo silhouette behind the
///    controls (blur + alpha-threshold, the CSS goo filter's equivalent).
///    At rest the pill is the web's Dynamic Island (src/routes/index.tsx):
///    speaker/status labels widen it sideways, a transcript drawer grows it
///    upward, and the mic stays pinned to screen centre.
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

  /// The user's in-flight words (empty once the turn finalizes).
  final String liveUser;

  /// Lumen's streaming words (empty once the assistant turn completes).
  final String liveAgent;

  /// A finalized turn is still being extracted ("Mapping").
  final bool extracting;

  /// Lumen owns the floor: the session is opening and Lumen's opening has
  /// not finished playing. The labels read Lumen, never You — the mic is not
  /// accepting speech yet.
  final bool openingInProgress;

  /// The latest graph upsert, shown as a chip above the dock.
  final UpsertActivity? activity;
  final bool muted;
  final bool expanded;
  final List<DockTurn> turns;
  final VoidCallback onMicTap;
  final VoidCallback? onToggleSplit;
  final VoidCallback? onMuteTap;

  const VoiceDock({
    super.key,
    this.mode = DockMode.idle,
    this.liveUser = '',
    this.liveAgent = '',
    this.extracting = false,
    this.openingInProgress = false,
    this.activity,
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

  // Button cluster: padding(6) + side(44) + mic(48) + side(44) + padding(6).
  static const double _clusterW = 148;
  static const double _collapsedH = 60;
  // Each flank's inner padding sums to 20 (web: pl-2 pr-3 / pl-3 pr-2).
  static const double _flankPad = 20;
  // Minimum gap between the pill and either screen edge (web: 1rem).
  static const double _edgeMargin = 16;
  // The web's pill easing and duration for every rest-pill morph.
  static const Curve _island = Cubic(0.32, 0.72, 0, 1);
  static const Duration _islandDuration = Duration(milliseconds: 300);

  // The rest pill's last laid-out width, so the split morph starts from
  // exactly the pill on screen (it widens past 148 when labels show).
  double _restW = 180;

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
    } else if (widget.expanded &&
        (widget.turns.length != old.turns.length ||
            (widget.turns.isNotEmpty &&
                widget.turns.last.text != old.turns.last.text))) {
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

    final activity = widget.activity;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The upsert chip rides above the dock (web: gap-2 in the dock
        // column). Keyed by activity id so each upsert replays the pop.
        if (activity != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _UpsertChip(
              key: ValueKey(activity.id),
              activity: activity,
              maxWidth: math.min(560, screen.width - 32),
            ),
          ),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _expand,
            child: _expandedContent(colors, maxBubble),
            builder: (context, child) {
              // Value-based branch (not status-based): on the tap frame the
              // controller is `forward` at value 0 — rendering the panel at
              // its 60px start would overflow the pinned buttons for that one
              // frame. At e ≤ 0 (rest, and the spring's squish tail on close)
              // show the pill; the first real morph frame is already tall
              // enough.
              if (_e.value <= 0) {
                return LayoutBuilder(
                  builder: (context, constraints) => _restDock(
                    context,
                    colors,
                    surface,
                    available: constraints.maxWidth,
                  ),
                );
              }
              // Morphing or open: the paper panel, sized by the spring.
              return _expandedDock(context, colors, surface, child!);
            },
          ),
        ),
      ],
    );
  }

  // ----- collapsed (rest) ---------------------------------------------------

  // Web state mapping (index.tsx:1144–1172). Connecting counts as listening,
  // exactly as the web's `live.listening` does before `ready`.
  bool get _listening =>
      widget.mode == DockMode.listening || widget.mode == DockMode.thinking;
  bool get _speaking => widget.mode == DockMode.speaking;
  bool get _ready => widget.mode != DockMode.thinking;

  ({String name, bool pulse})? get _leftLabel {
    if (widget.openingInProgress) return (name: 'Lumen', pulse: _speaking);
    if (_speaking || widget.liveAgent.isNotEmpty) {
      return (name: 'Lumen', pulse: _speaking);
    }
    if (_listening) return (name: 'You', pulse: true);
    if (widget.extracting) return (name: 'Mapping', pulse: false);
    return null;
  }

  ({String name, bool pulse})? get _rightLabel {
    if (_speaking) return (name: 'Speaking', pulse: true);
    // Before (or between chunks of) the opening: still connecting to Lumen.
    if (widget.openingInProgress) return (name: 'Connecting', pulse: false);
    if (_listening) {
      return (name: _ready ? 'Listening' : 'Connecting', pulse: _ready);
    }
    if (widget.extracting) return (name: 'Mapping', pulse: false);
    return null;
  }

  bool get _islandExpanded =>
      _listening ||
      _speaking ||
      widget.liveAgent.isNotEmpty ||
      widget.extracting ||
      widget.openingInProgress;

  // During the opening the user's mic is gated, so only Lumen's words can
  // open the drawer — and they stay through a mid-opening lull.
  bool get _drawerOpen => widget.openingInProgress
      ? widget.liveAgent.isNotEmpty
      : (_speaking && widget.liveAgent.isNotEmpty) ||
          (_listening && widget.liveUser.isNotEmpty);

  Widget _restDock(
    BuildContext context,
    LumenColors colors,
    LumenSurface surface, {
    required double available,
  }) {
    final left = _leftLabel;
    final right = _rightLabel;
    final expanded = _islandExpanded;
    final drawerOpen = _drawerOpen;

    // Column math, verbatim from index.tsx:1176–1202. TextPainter measures
    // the labels synchronously, so there is no measure-then-rerender pass.
    // Web: maxWidth min(560px, 100vw − 2rem) — and never past the slot the
    // parent actually gives the dock.
    final screenW = MediaQuery.sizeOf(context).width;
    // The frame the dock is centred in (the parent slot, at most the screen).
    final frameW = math.min(screenW, available);
    final maxPill = math.max(
      _clusterW,
      math.min(560.0, math.min(screenW - 2 * _edgeMargin, available)),
    );
    final minPill = math.min(drawerOpen ? 340.0 : 180.0, maxPill);
    final leftNat = expanded && left != null
        ? _SpeakerLabel.measure(left.name, left.pulse, colors) + _flankPad
        : 0.0;
    final rightNat = expanded && right != null
        ? _SpeakerLabel.measure(right.name, right.pulse, colors) + _flankPad
        : 0.0;
    final maxFlanks = math.max(0.0, maxPill - _clusterW);
    final minFlanks = math.max(0.0, minPill - _clusterW);
    final natural = leftNat + rightNat;
    final minPad = natural < minFlanks ? (minFlanks - natural) / 2 : 0.0;
    var leftCol = leftNat + minPad;
    var rightCol = rightNat + minPad;
    final overflow = leftCol + rightCol - maxFlanks;
    if (overflow > 0) {
      final rightTrim = math.min(rightCol, overflow);
      rightCol -= rightTrim;
      final remaining = overflow - rightTrim;
      if (remaining > 0) leftCol = math.max(0, leftCol - remaining);
    }
    _restW = _clusterW + leftCol + rightCol;

    final drawerText = _speaking || widget.openingInProgress
        ? widget.liveAgent
        : widget.liveUser;

    // One tween drives both flank columns, so pill width, flank widths and
    // the mic-pinning shift always agree mid-animation (separate implicit
    // animations could drift a frame apart and overflow the row).
    return TweenAnimationBuilder<Offset>(
      tween: Tween(end: Offset(leftCol, rightCol)),
      duration: _islandDuration,
      curve: _island,
      builder: (context, cols, _) {
        final l = math.max(0.0, cols.dx);
        final r = math.max(0.0, cols.dy);
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drawer: sits ABOVE the buttons so the bottom edge holds still
            // and the pill grows upward — Dynamic Island style.
            AnimatedSize(
              duration: _islandDuration,
              curve: _island,
              alignment: Alignment.bottomCenter,
              child: drawerOpen
                  ? _drawer(colors, drawerText)
                  : const SizedBox(width: double.infinity),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _flank(colors, left, l, expanded,
                      padding: const EdgeInsets.only(left: 8, right: 12)),
                  _SplitControl(
                    active: widget.expanded,
                    onTap: widget.onToggleSplit,
                    colors: colors,
                  ),
                  _mic(colors),
                  _volume(colors),
                  _flank(colors, right, r, expanded,
                      padding: const EdgeInsets.only(left: 12, right: 8)),
                ],
              ),
            ),
          ],
        );

        // Mic-pinning shift: the mic sits _clusterW/2 from the pill's own
        // centre; translating by (right − left)/2 lands it back on screen
        // centre. It wraps the silhouette too, so goo and pill move together.
        // Unlike the web, the shift is capped so neither edge enters the 16pt
        // screen margin — on a phone the pill is often nearly full-width, and
        // the margin matters more than a perfectly centred mic.
        final pillW = _clusterW + l + r;
        final maxShift = math.max(0.0, (frameW - pillW) / 2 - _edgeMargin);
        final shift = ((r - l) / 2).clamp(-maxShift, maxShift);
        return Transform.translate(
          offset: Offset(shift, 0),
          child: SizedBox(
            width: pillW,
            child: _voiceActive
                // Living silhouette paints the capsule itself; controls ride
                // on top. The painter listens to the pulse clock directly
                // (repaint:), so its 60fps drift rebuilds no widgets, and it
                // sizes to the morphing pill for free.
                ? CustomPaint(
                    painter: _GooPainter(
                      pulse: _pulse,
                      fill: colors.card,
                      rim: colors.border,
                      shadow: colors.ink.withValues(alpha: 0.10),
                    ),
                    child: content,
                  )
                // The border paints as a foreground so it takes no layout
                // space — the row needs the pill's full computed width.
                : Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: surface.shadowPaper,
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: colors.border),
                    ),
                    child: content,
                  ),
          ),
        );
      },
    );
  }

  // The transcript drawer: at most four lines, anchored to the newest words
  // (a reversed viewport keeps the tail in view as text streams in).
  Widget _drawer(LumenColors colors, String text) {
    const style = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 13.5,
      height: 1.55,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 13.5 * 1.55 * 4),
        child: SingleChildScrollView(
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: double.infinity,
            child: Text(
              text.isEmpty ? '…' : text,
              style: style.copyWith(color: colors.ink),
            ),
          ),
        ),
      ),
    );
  }

  // One label flank. Its column width comes from the shared tween; the label
  // keeps its natural width and is clipped while the column is narrower.
  // Fades in over 300ms after a 200ms delay, out in 100ms (web timing).
  Widget _flank(
    LumenColors colors,
    ({String name, bool pulse})? label,
    double width,
    bool expanded, {
    required EdgeInsets padding,
  }) {
    return SizedBox(
      width: width,
      height: 48,
      child: ClipRect(
        child: AnimatedOpacity(
          opacity: expanded ? 1 : 0,
          duration: Duration(milliseconds: expanded ? 500 : 100),
          curve: expanded
              ? const Interval(0.4, 1.0, curve: Curves.linear)
              : Curves.linear,
          child: OverflowBox(
            alignment: Alignment.centerRight,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Padding(
              padding: padding,
              child: label == null
                  ? const SizedBox.shrink()
                  : _SpeakerLabel(
                      name: label.name,
                      pulse: label.pulse,
                      colors: colors,
                    ),
            ),
          ),
        ),
      ),
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
    final w = lerpDouble(_restW, expandedW, ew)!;
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
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
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
              _volume(colors),
            ],
          ),
        ),
      ],
    );
  }

  Widget _conversation(LumenColors colors, double maxBubble) {
    // [turns] arrive in spoken order, unfinished utterances included as
    // pending — each keeps its slot from first word to finalization, so the
    // pane never reorders or drops a line while Gemini's finals lag.
    final rows = <Widget>[
      for (final turn in widget.turns)
        _bubble(colors, turn.speaker, turn.text, maxBubble,
            pending: turn.pending),
    ];

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

  Widget _volume(LumenColors colors) => _SideControl(
        icon: widget.muted ? Icons.volume_off : Icons.volume_up,
        color: colors.mutedForeground,
        onTap: widget.onMuteTap,
      );

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

/// The web's SpeakerLabel: 10px caps at 0.22em tracking, with an amber
/// ping dot while that side is live.
class _SpeakerLabel extends StatelessWidget {
  final String name;
  final bool pulse;
  final LumenColors colors;

  const _SpeakerLabel({
    required this.name,
    required this.pulse,
    required this.colors,
  });

  static const double _dot = 6;
  static const double _gap = 6;

  static TextStyle _style(LumenColors colors) =>
      LumenText.eyebrow(colors.mutedForeground).copyWith(
        fontWeight: FontWeight.w500,
        letterSpacing: 2.2, // 0.22em at 10px
      );

  /// Natural width, for the pill's column math (the web measures the same
  /// slot with a ResizeObserver).
  static double measure(String name, bool pulse, LumenColors colors) {
    final painter = TextPainter(
      text: TextSpan(text: name.toUpperCase(), style: _style(colors)),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width + (pulse ? _dot + _gap : 0);
    painter.dispose();
    return width.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pulse) ...[
          _PingDot(color: colors.amber),
          const SizedBox(width: _gap),
        ],
        Text(name.toUpperCase(), maxLines: 1, style: _style(colors)),
      ],
    );
  }
}

/// Tailwind's `animate-ping` on a 6px dot: a ring that scales to 2× and
/// fades, over a steady core.
class _PingDot extends StatefulWidget {
  final Color color;
  const _PingDot({required this.color});

  @override
  State<_PingDot> createState() => _PingDotState();
}

class _PingDotState extends State<_PingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ping = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = DecoratedBox(
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    return SizedBox(
      width: _SpeakerLabel._dot,
      height: _SpeakerLabel._dot,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _ping,
            builder: (context, child) {
              // cubic-bezier(0,0,.2,1); fully out by 75% of the cycle.
              final t = const Interval(0, 0.75, curve: Cubic(0, 0, 0.2, 1))
                  .transform(_ping.value);
              return Opacity(
                opacity: 0.75 * (1 - t),
                child: Transform.scale(scale: 1 + t, child: child),
              );
            },
            child: dot,
          ),
          dot,
        ],
      ),
    );
  }
}

/// The web's "Upserting" chip (index.tsx:1368–1390) with its `upsert-pop`
/// entrance: rise 8px and scale .98→1 while an amber ring blooms and fades
/// over the first 45% of 1.25s, then settle onto the paper shadow.
class _UpsertChip extends StatefulWidget {
  final UpsertActivity activity;
  final double maxWidth;

  const _UpsertChip({
    super.key,
    required this.activity,
    required this.maxWidth,
  });

  @override
  State<_UpsertChip> createState() => _UpsertChipState();
}

class _UpsertChipState extends State<_UpsertChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  )..forward();

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    final a = widget.activity;
    final small = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 11,
      color: colors.mutedForeground,
    );
    Widget chip(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: colors.paper,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
          ),
          child: Text(
            text,
            style: small.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
        );

    final body = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Icon(Icons.waves, size: 14, color: colors.amber),
        Text('UPSERTING', style: LumenText.eyebrow(colors.mutedForeground)),
        for (final name in a.entityNames.take(4)) chip(name),
        if (a.entityNames.length > 4) chip('+${a.entityNames.length - 4}'),
        Text(
          '${a.insertedEntities} new · ${a.updatedEntities} refreshed · '
          '${a.createdRelations} links',
          style: small,
        ),
      ],
    );

    return AnimatedBuilder(
      animation: _pop,
      builder: (context, child) {
        final rise = Curves.easeOut
            .transform(const Interval(0, 0.45).transform(_pop.value));
        final ring = const Interval(0, 0.45).transform(_pop.value);
        final settle = const Interval(0.45, 1).transform(_pop.value);
        return Opacity(
          opacity: rise,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - rise)),
            child: Transform.scale(
              scale: 0.98 + 0.02 * rise,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    if (ring < 1)
                      BoxShadow(
                        color: colors.amber.withValues(alpha: 0.45 * (1 - ring)),
                        spreadRadius: 10 * ring,
                      ),
                    for (final shadow in surface.shadowPaper)
                      shadow.scale(settle),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        );
      },
      child: Container(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: colors.card.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colors.border),
        ),
        child: body,
      ),
    );
  }
}

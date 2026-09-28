import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/entity_highlighter.dart';
import '../../models/upsert_activity.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/node_glyph.dart';

/// Dock state — drives the mic and the speaker chips. Mapped from
/// SessionStatus at the call site.
enum DockMode { idle, listening, speaking, thinking }

/// Who spoke a turn.
enum DockSpeaker { you, lumen }

/// What fills the screen behind the dock: the knowledge graph, or the whole
/// conversation as a rolling transcript. The dock's outer buttons switch it.
enum JournalView { graph, transcript }

/// The bottom voice dock ("pill E"): a symmetric two-tier card.
///
///  * Top tier — You | Lumen chips. The one holding the floor lights up in its
///    colour with a live status ("Listening", "Speaking", "Connecting").
///  * Drawer — in graph view only, the in-flight words open between the tiers
///    (up to three lines, newest anchored), entities marked in their graph
///    colours. In transcript view the page is the transcript, so it stays shut.
///  * Bottom tier — graph · speaker · mic · end · transcript. Graph and
///    transcript are one mode switch split across the mic; a dot marks the
///    active view. Tapping one reports [onViewChanged]; the screen runs the
///    page transition. The mic sits on the dock's centre line by construction.
class VoiceDock extends StatefulWidget {
  final DockMode mode;

  /// The user's in-flight words (empty once the turn finalizes).
  final String liveUser;

  /// Lumen's streaming words (empty once the assistant turn completes).
  final String liveAgent;

  /// A finalized turn is still being extracted ("Mapping").
  final bool extracting;

  /// Lumen owns the floor: the session is opening and Lumen's opening has
  /// not finished playing. The chips read Lumen, never You — the mic is not
  /// accepting speech yet.
  final bool openingInProgress;

  /// The mic is paused mid-session; the next mic tap resumes it.
  final bool paused;

  /// The connection is being restored; the conversation keeps its context.
  final bool reconnecting;

  /// The latest graph upsert, shown as a chip above the dock.
  final UpsertActivity? activity;
  final bool muted;
  final JournalView view;

  /// Names to mark in the drawer, from the graph.
  final List<HighlightTerm> terms;
  final VoidCallback onMicTap;
  final ValueChanged<JournalView>? onViewChanged;
  final VoidCallback? onMuteTap;

  /// Ends the live session; null (drawn dimmed) when there is none.
  final VoidCallback? onEndTap;

  const VoiceDock({
    super.key,
    this.mode = DockMode.idle,
    this.liveUser = '',
    this.liveAgent = '',
    this.extracting = false,
    this.openingInProgress = false,
    this.paused = false,
    this.reconnecting = false,
    this.activity,
    this.muted = false,
    this.view = JournalView.graph,
    this.terms = const [],
    required this.onMicTap,
    this.onViewChanged,
    this.onMuteTap,
    this.onEndTap,
  });

  @override
  State<VoiceDock> createState() => _VoiceDockState();
}

class _VoiceDockState extends State<VoiceDock>
    with SingleTickerProviderStateMixin {
  // The mic pulse: the listening ring and the thinking breath share it.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  // The drawer's spring, matching the web dock: a soft overshoot on open.
  static const Curve _spring = Cubic(0.34, 1.56, 0.64, 1);
  static const Duration _springDuration = Duration(milliseconds: 520);
  static const double _dockW = 320;

  bool get _pulseActive =>
      widget.mode == DockMode.listening || widget.mode == DockMode.thinking;

  @override
  void initState() {
    super.initState();
    if (_pulseActive) _pulse.repeat();
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
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  // ----- who holds the floor -------------------------------------------------

  // Connecting counts as listening, exactly as the web's `live.listening`
  // does before `ready`.
  bool get _listening =>
      widget.mode == DockMode.listening || widget.mode == DockMode.thinking;
  bool get _speaking => widget.mode == DockMode.speaking;

  bool get _lumenHolds =>
      widget.reconnecting ||
      widget.openingInProgress ||
      _speaking ||
      widget.liveAgent.isNotEmpty;
  bool get _youHold => !_lumenHolds && (_listening || widget.paused);

  String? get _youStatus {
    if (!_youHold) return null;
    if (widget.paused) return 'Paused';
    return widget.mode == DockMode.thinking ? 'Connecting' : 'Listening';
  }

  String? get _lumenStatus {
    if (widget.reconnecting) return 'Reconnecting';
    if (_speaking) return 'Speaking';
    if (widget.openingInProgress) return 'Connecting';
    if (widget.liveAgent.isNotEmpty) return 'Speaking';
    if (!_listening && widget.extracting) return 'Mapping';
    return null;
  }

  // During the opening the user's mic is gated, so only Lumen's words can
  // open the drawer — and they stay through a mid-opening lull.
  bool get _drawerOpen {
    if (widget.view != JournalView.graph) return false;
    if (widget.openingInProgress) return widget.liveAgent.isNotEmpty;
    return (_speaking && widget.liveAgent.isNotEmpty) ||
        (_listening && widget.liveUser.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final surface = Theme.of(context).extension<LumenSurface>()!;
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(_dockW, screen.width - 32);
    final activity = widget.activity;
    final lumenWords = _speaking || widget.openingInProgress;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The upsert chip rides above the dock. Keyed by activity id so each
        // upsert replays the pop.
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
          child: Container(
            width: width,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.card,
              borderRadius: BorderRadius.circular(28),
              boxShadow: surface.shadowPaper,
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: _SpeakerChip(
                          name: 'You',
                          status: _youStatus,
                          color: colors.amber,
                          colors: colors,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: _SpeakerChip(
                          name: 'Lumen',
                          status: _lumenStatus,
                          color: colors.sage,
                          colors: colors,
                        ),
                      ),
                    ],
                  ),
                ),
                // Drawer: grows between the tiers so the controls never move.
                AnimatedSize(
                  duration: _springDuration,
                  curve: _spring,
                  alignment: Alignment.bottomCenter,
                  child: _drawerOpen
                      ? _Drawer(
                          text: lumenWords ? widget.liveAgent : widget.liveUser,
                          lumen: lumenWords,
                          terms: widget.terms,
                          colors: colors,
                        )
                      : const SizedBox(width: double.infinity, height: 6),
                ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 18),
                  color: colors.border,
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ModeButton(
                        icon: Icons.hub_outlined,
                        label: 'Graph view',
                        active: widget.view == JournalView.graph,
                        colors: colors,
                        onTap: _switchTo(JournalView.graph),
                      ),
                      _SideControl(
                        icon: widget.muted ? Icons.volume_off : Icons.volume_up,
                        label: widget.muted ? 'Unmute Lumen' : 'Mute Lumen',
                        color: colors.mutedForeground,
                        onTap: widget.onMuteTap,
                      ),
                      const SizedBox(width: 4),
                      _mic(colors),
                      const SizedBox(width: 4),
                      _SideControl(
                        icon: Icons.stop_circle_outlined,
                        label: 'End session',
                        color: widget.onEndTap == null
                            ? colors.mutedForeground.withValues(alpha: 0.35)
                            : colors.mutedForeground,
                        onTap: widget.onEndTap,
                      ),
                      _ModeButton(
                        icon: Icons.article_outlined,
                        label: 'Transcript view',
                        active: widget.view == JournalView.transcript,
                        colors: colors,
                        onTap: _switchTo(JournalView.transcript),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  VoidCallback? _switchTo(JournalView view) {
    final cb = widget.onViewChanged;
    if (cb == null) return null;
    return () {
      if (widget.view != view) cb(view);
    };
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
          // breath per pulse cycle — "booting up," not "recording".
          final thinkingBreath =
              0.55 + 0.20 * (0.5 + 0.5 * math.sin(math.pi * t));
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
              Semantics(
                button: true,
                label: 'Microphone',
                child: GestureDetector(
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
                    child: Icon(
                      widget.paused ? Icons.mic_off : Icons.mic,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One side of the top tier. Active (a [status] is set): tinted in its
/// speaker colour with a ping dot and the status word. Inactive: dimmed.
class _SpeakerChip extends StatelessWidget {
  final String name;
  final String? status;
  final Color color;
  final LumenColors colors;

  const _SpeakerChip({
    required this.name,
    required this.status,
    required this.color,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final active = status != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      height: 36,
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: active ? 1 : 0.45,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (active)
              _PingDot(color: color)
            else
              SizedBox(
                width: 6,
                height: 6,
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            const SizedBox(width: 7),
            Text(
              name,
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: colors.ink,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  status!,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    fontFamily: LumenText.sansFontFamily,
                    fontSize: 12,
                    color: colors.mutedForeground,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The in-flight words between the tiers: at most three lines, anchored to
/// the newest (a reversed viewport keeps the tail in view as text streams),
/// entities marked in their graph colours.
class _Drawer extends StatelessWidget {
  final String text;
  final bool lumen;
  final List<HighlightTerm> terms;
  final LumenColors colors;

  const _Drawer({
    required this.text,
    required this.lumen,
    required this.terms,
    required this.colors,
  });

  static const double _lineH = 22;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontFamily:
          lumen ? LumenText.displayFontFamily : LumenText.sansFontFamily,
      fontSize: lumen ? 15 : 14,
      height: _lineH / (lumen ? 15 : 14),
      color: colors.ink,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _lineH * 3),
        child: SingleChildScrollView(
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: double.infinity,
            child: Text.rich(
              TextSpan(
                style: base,
                children: text.isEmpty
                    ? const [TextSpan(text: '…')]
                    : highlightSpans(text, terms),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// Transcript text as spans: each entity mention washed in its graph colour,
/// Kindle-style. Shared by the dock drawer and the transcript page.
List<InlineSpan> highlightSpans(String text, List<HighlightTerm> terms) => [
      for (final run in highlightRuns(text, terms))
        TextSpan(
          text: run.text,
          style: run.type == null
              ? null
              : TextStyle(
                  backgroundColor:
                      colorForEntityType(run.type!).withValues(alpha: 0.30),
                ),
        ),
    ];

/// One half of the view switch. The dot beneath springs in under the active
/// view.
class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final LumenColors colors;
  final VoidCallback? onTap;

  const _ModeButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.colors,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: 19,
                color: active ? colors.ink : colors.mutedForeground,
              ),
              Positioned(
                bottom: 3,
                child: AnimatedScale(
                  scale: active ? 1 : 0,
                  duration: const Duration(milliseconds: 240),
                  curve: const Cubic(0.34, 1.56, 0.64, 1),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.amber,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _SideControl({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
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
      width: 6,
      height: 6,
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
                        color:
                            colors.amber.withValues(alpha: 0.45 * (1 - ring)),
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

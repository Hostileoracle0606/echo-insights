import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/entity_highlighter.dart';
import '../../models/upsert_activity.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/node_glyph.dart';

/// Dock state — drives the mic and the status label. Mapped from
/// SessionStatus at the call site.
enum DockMode { idle, listening, speaking, thinking }

/// Who spoke a turn.
enum DockSpeaker { you, lumen }

/// What fills the screen behind the dock: the knowledge graph, or the whole
/// conversation as a rolling transcript. The pill's View button switches it.
enum JournalView { graph, transcript }

/// The bottom control on every conversation screen ("the pill"): one row of
/// Type · Talk · View, with a status tier that opens above it.
///
///  * Row — `[Type 44] 14 [mic 48] 14 [View 44]`. Type turns the pill into a
///    composer ([onTypeTap]); the mic is Talk; View toggles graph ⇄ transcript
///    ([onViewChanged]) and shows the view it would switch *to*. A missing
///    callback leaves an empty 44pt slot rather than a dead button, so the mic
///    stays on the centre line by construction.
///  * Tier — while someone holds the floor, one label line ("You · Listening"
///    in amber, "Lumen · Speaking" in sage). In graph view the in-flight words
///    ride under it (up to three lines, newest anchored, entities marked in
///    their graph colours); in transcript view the page is the transcript, so
///    only the label shows.
///  * Width — at rest the pill hugs its row (184pt). When the tier or a
///    [composer] appears it springs out to `min(358, screen − 32)` and back.
///    Reduced motion resizes at once.
///  * [composer] — when set, replaces the row (the tier stays above it).
///
/// The widget only reads its props and calls back; session logic and
/// providers stay with the screen, so other screens can reuse the pill.
class VoiceDock extends StatefulWidget {
  final DockMode mode;

  /// The user's in-flight words (empty once the turn finalizes).
  final String liveUser;

  /// Lumen's streaming words (empty once the assistant turn completes).
  final String liveAgent;

  /// A finalized turn is still being extracted ("Mapping").
  final bool extracting;

  /// Lumen owns the floor: the session is opening and Lumen's opening has
  /// not finished playing. The label reads Lumen, never You — the mic is not
  /// accepting speech yet.
  final bool openingInProgress;

  /// The mic is paused mid-session; the next mic tap resumes it.
  final bool paused;

  /// The connection is being restored; the conversation keeps its context.
  final bool reconnecting;

  /// The latest graph upsert, shown as a chip above the pill.
  final UpsertActivity? activity;
  final JournalView view;

  /// Names to mark in the live words, from the graph.
  final List<HighlightTerm> terms;
  final VoidCallback onMicTap;

  /// Asks for the other view; null leaves the View slot empty.
  final ValueChanged<JournalView>? onViewChanged;

  /// Opens the text composer; null leaves the Type slot empty.
  final VoidCallback? onTypeTap;

  /// Replaces the button row while set (the typed-turn composer).
  final Widget? composer;

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
    this.view = JournalView.graph,
    this.terms = const [],
    required this.onMicTap,
    this.onViewChanged,
    this.onTypeTap,
    this.composer,
  });

  /// The pill's card, for tests that measure its width.
  @visibleForTesting
  static const Key pillKey = ValueKey('voice-dock-pill');

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

  // The pill's spring, matching the web dock: a soft overshoot on open.
  static const Curve _spring = Cubic(0.34, 1.56, 0.64, 1);
  static const Duration _springDuration = Duration(milliseconds: 520);
  static const double _wideW = 358;
  static const double _button = 44;
  static const double _gap = 14;
  // 10 + 44 + 14 + 48 + 14 + 44 + 10 = 184.
  static const double _restW = 2 * 10 + 2 * _button + 2 * _gap + 48;

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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final activity = widget.activity;
    final lumenWords = _speaking || widget.openingInProgress;

    // One speaker at a time. You only holds a status while Lumen doesn't hold
    // the floor, so this only settles "You · Paused" over "Lumen · Mapping".
    final youStatus = _youStatus;
    final lumen = youStatus == null;
    final status = youStatus ?? _lumenStatus;
    final tier = status != null;
    final wide = tier || widget.composer != null;
    final wideW = math.max(_restW, math.min(_wideW, screen.width - 32));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The upsert chip rides above the pill. Keyed by activity id so each
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
            key: VoiceDock.pillKey,
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
            child: _springSize(
              reduceMotion: reduceMotion,
              child: SizedBox(
                width: wide ? wideW : _restW,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tier)
                      _Tier(
                        name: lumen ? 'Lumen' : 'You',
                        status: status,
                        color: lumen ? colors.sage : colors.amber,
                        words: _drawerOpen
                            ? _Drawer(
                                text: lumenWords
                                    ? widget.liveAgent
                                    : widget.liveUser,
                                lumen: lumenWords,
                                terms: widget.terms,
                                colors: colors,
                              )
                            : null,
                        fadeIn: !reduceMotion,
                        colors: colors,
                      ),
                    AnimatedSwitcher(
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      child: widget.composer == null
                          ? KeyedSubtree(
                              key: const ValueKey('row'),
                              child: _row(colors),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('composer'),
                              child: widget.composer!,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // AnimatedSize lays the child out at its final size and clips while the box
  // springs, so the overshoot can never overflow the row. Bottom-centre keeps
  // the row (and the mic) still as the tier opens above it. Reduced motion
  // resizes at once (a zero-length AnimatedSize re-dirties its own layout).
  Widget _springSize({required bool reduceMotion, required Widget child}) {
    if (reduceMotion) return child;
    return AnimatedSize(
      duration: _springDuration,
      curve: _spring,
      alignment: Alignment.bottomCenter,
      child: child,
    );
  }

  Widget _row(LumenColors colors) {
    final onType = widget.onTypeTap;
    final onView = widget.onViewChanged;
    final graph = widget.view == JournalView.graph;
    const empty = SizedBox(width: _button, height: _button);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onType == null)
            empty
          else
            _PillButton(
              icon: Icons.keyboard_outlined,
              label: 'Type instead',
              colors: colors,
              onTap: onType,
            ),
          const SizedBox(width: _gap),
          _mic(colors),
          const SizedBox(width: _gap),
          if (onView == null)
            empty
          else
            _PillButton(
              icon: graph ? Icons.article_outlined : Icons.hub_outlined,
              label: graph ? 'Show transcript' : 'Show graph',
              colors: colors,
              onTap: () => onView(
                graph ? JournalView.transcript : JournalView.graph,
              ),
            ),
        ],
      ),
    );
  }

  Widget _mic(LumenColors colors) {
    final listening = widget.mode == DockMode.listening;
    final thinking = widget.mode == DockMode.thinking;
    // Scoped to its own AnimatedBuilder: the pulse animates only this 48×48
    // subtree (ring + fill), never the rest of the pill.
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
                      // The resting halo: a 5pt amber ring at 22%.
                      boxShadow: [
                        BoxShadow(
                          color: colors.amber.withValues(alpha: 0.22),
                          spreadRadius: 5,
                        ),
                      ],
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

/// The status tier: one label line (ping dot · speaker · status) and, in
/// graph view, the live words under it. The label is a live region so
/// VoiceOver announces each change of floor.
class _Tier extends StatelessWidget {
  final String name;
  final String status;
  final Color color;
  final Widget? words;
  final bool fadeIn;
  final LumenColors colors;

  const _Tier({
    required this.name,
    required this.status,
    required this.color,
    required this.words,
    required this.fadeIn,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final label = Semantics(
      liveRegion: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PingDot(color: color),
          const SizedBox(width: 7),
          Text(
            name,
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Text(
            ' · ',
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 12.5,
              color: color,
            ),
          ),
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [label, if (words != null) words!],
      ),
    );
    if (!fadeIn) return body;
    // A short fade as the pill springs open; the spring's clip does the exit.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: body,
    );
  }
}

/// The in-flight words under the status label: at most three lines, anchored
/// to the newest (a reversed viewport keeps the tail in view as text streams),
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
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
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
/// Kindle-style. Shared by the pill's live words and the transcript page.
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

/// A 44pt icon button in the pill's row (Type, View).
class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final LumenColors colors;
  final VoidCallback onTap;

  const _PillButton({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 19, color: colors.ink),
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

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/entity_highlighter.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../theme/lumen_theme.dart';
import 'voice_dock.dart' show DockSpeaker, highlightSpans;

/// One utterance on the transcript page.
class TranscriptTurn {
  /// Stable across rebuilds, so a turn animates in once and then holds.
  final String id;
  final DockSpeaker speaker;
  final String text;

  /// Still being transcribed — drawn faded, in its spoken slot.
  final bool pending;

  /// When it was spoken (its first transcript chunk).
  final DateTime? at;

  const TranscriptTurn(
    this.speaker,
    this.text, {
    this.id = '',
    this.pending = false,
    this.at,
  });
}

/// The transcript view: the whole conversation as a rolling page of text,
/// entities marked in their graph colours. It replaces the graph behind the
/// dock (the screen runs the page transition) and follows the newest words
/// unless the reader has scrolled back, when a chip offers the way down.
class TranscriptPage extends StatefulWidget {
  final List<TranscriptTurn> turns;
  final List<HighlightTerm> terms;

  /// The page transition, 0 → 1. Turns fade up from the newest as it lands.
  final Animation<double> entrance;

  /// Space the floating top bar and dock cover.
  final double topInset;
  final double bottomInset;

  /// Who is speaking right now, for the jump chip's label.
  final DockSpeaker? liveSpeaker;

  const TranscriptPage({
    super.key,
    required this.turns,
    this.terms = const [],
    this.entrance = kAlwaysCompleteAnimation,
    this.topInset = 0,
    this.bottomInset = 0,
    this.liveSpeaker,
  });

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final ScrollController _scroll = ScrollController();
  bool _awayFromLatest = false;

  // Turns mounted before the page was shown enter with the page's stagger;
  // anything that arrives later gets its own short fade-up.
  late final Set<String> _seen = {for (final t in widget.turns) t.id};

  static const _stagger = 8;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // The list is reversed: offset 0 is the newest line, so staying pinned to
  // it needs no work at all. Past a screenful up, offer the way back.
  void _onScroll() {
    final away = _scroll.hasClients && _scroll.offset > 160;
    if (away != _awayFromLatest) setState(() => _awayFromLatest = away);
  }

  void _jumpToLatest() {
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final turns = widget.turns;
    final firstAt = turns.isEmpty ? null : turns.first.at;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (turns.isEmpty)
          _Empty(colors: colors, entrance: widget.entrance)
        else
          ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(
                24, widget.topInset + 8, 24, widget.bottomInset + 16),
            // +1: the day header sits above the oldest turn.
            itemCount: turns.length + 1,
            itemBuilder: (context, i) {
              if (i == turns.length) {
                return _Staggered(
                  entrance: widget.entrance,
                  rank: math.min(i, _stagger),
                  child: _DayHeader(at: firstAt, colors: colors),
                );
              }
              final turn = turns[turns.length - 1 - i];
              final fresh = !_seen.contains(turn.id);
              if (fresh) _seen.add(turn.id);
              return Padding(
                key: turn.id.isEmpty ? null : ValueKey(turn.id),
                padding: EdgeInsets.only(top: i == turns.length - 1 ? 0 : 22),
                child: _Staggered(
                  entrance: widget.entrance,
                  rank: math.min(i, _stagger),
                  child: _Arrival(
                    animate: fresh,
                    child: _TurnView(
                        turn: turn, terms: widget.terms, colors: colors),
                  ),
                ),
              );
            },
          ),
        // Soft edge under the floating top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: widget.topInset + 24,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.6, 1],
                  colors: [colors.paper, colors.paper.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
        ),
        // Text slides under the dock and fades out.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: widget.bottomInset + 40,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.45],
                  colors: [colors.paper.withValues(alpha: 0), colors.paper],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.bottomInset + 12,
          child: Center(
            child: AnimatedSlide(
              offset: _awayFromLatest ? Offset.zero : const Offset(0, 0.4),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _awayFromLatest ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_awayFromLatest,
                  child: _JumpChip(
                    speaker: widget.liveSpeaker,
                    colors: colors,
                    onTap: _jumpToLatest,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Entrance stagger: rank 0 (the newest turn) leads, each older one follows
/// 40ms behind, riding the page transition's own clock.
class _Staggered extends StatelessWidget {
  final Animation<double> entrance;
  final int rank;
  final Widget child;

  const _Staggered({
    required this.entrance,
    required this.rank,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // The page transition runs ~580ms; turns start at ~200ms, 320ms each.
    final start = (0.34 + rank * 0.07).clamp(0.0, 0.8);
    final end = (start + 0.55).clamp(0.0, 1.0);
    final t = CurvedAnimation(
      parent: entrance,
      curve: Interval(start, end, curve: Curves.easeOut),
    );
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(t),
        child: child,
      ),
    );
  }
}

/// A turn that arrives while the page is open fades up once. Whether it
/// animates is fixed at mount, so rebuilds mid-fade (it is still streaming)
/// never cut the fade short.
class _Arrival extends StatefulWidget {
  final bool animate;
  final Widget child;

  const _Arrival({required this.animate, required this.child});

  @override
  State<_Arrival> createState() => _ArrivalState();
}

class _ArrivalState extends State<_Arrival> {
  late final bool _animate = widget.animate;

  @override
  Widget build(BuildContext context) {
    if (!_animate) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      child: widget.child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child:
            Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  final TranscriptTurn turn;
  final List<HighlightTerm> terms;
  final LumenColors colors;

  const _TurnView({
    required this.turn,
    required this.terms,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final lumen = turn.speaker == DockSpeaker.lumen;
    final dot = lumen ? colors.sage : colors.amber;
    final style = lumen
        ? const TextStyle(
            fontFamily: LumenText.displayFontFamily,
            fontSize: 18,
            height: 28 / 18,
            color: Color(0xFF3A2A1E),
            fontVariations: [
              FontVariation('wght', 380),
              FontVariation('opsz', 18),
            ],
          )
        : TextStyle(
            fontFamily: LumenText.sansFontFamily,
            fontSize: 16,
            height: 26 / 16,
            color: colors.ink,
          );
    final at = turn.at;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(lumen ? 'LUMEN' : 'YOU', style: LumenText.eyebrow(dot)),
            if (at != null) ...[
              const SizedBox(width: 8),
              Text(
                _clock(at),
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 11,
                  color: colors.mutedForeground.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: turn.pending ? 0.6 : 1,
          child: Text.rich(
            TextSpan(style: style, children: highlightSpans(turn.text, terms)),
          ),
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  final DateTime? at;
  final LumenColors colors;

  const _DayHeader({required this.at, required this.colors});

  @override
  Widget build(BuildContext context) {
    final day = (at ?? DateTime.now()).toLocal();
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            at == null ? 'TRANSCRIPT' : 'TRANSCRIPT · STARTED ${_clock(at!)}',
            style: LumenText.eyebrow(colors.mutedForeground),
          ),
          const SizedBox(height: 6),
          Text(
            longDate(day),
            style: textTheme.displaySmall?.copyWith(letterSpacing: -0.5),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: colors.border),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final LumenColors colors;
  final Animation<double> entrance;

  const _Empty({required this.colors, required this.entrance});

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: entrance,
        curve: const Interval(0.4, 1, curve: Curves.easeOut),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            'Your conversation will appear here as you speak.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: LumenText.displayFontFamily,
              fontSize: 18,
              height: 1.5,
              color: colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

class _JumpChip extends StatelessWidget {
  final DockSpeaker? speaker;
  final LumenColors colors;
  final VoidCallback onTap;

  const _JumpChip({
    required this.speaker,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).extension<LumenSurface>()!;
    final who = switch (speaker) {
      DockSpeaker.lumen => 'Lumen is speaking · ',
      DockSpeaker.you => 'Listening · ',
      null => '',
    };
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
            boxShadow: surface.shadowPaper,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 15, color: colors.ink),
              const SizedBox(width: 6),
              Text(
                '${who}Jump to latest',
                style: TextStyle(
                  fontFamily: LumenText.sansFontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: colors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "9:41" — the transcript's quiet time stamp, local time.
String _clock(DateTime at) {
  final t = at.toLocal();
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')}';
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "Thursday, 25 September".
String longDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

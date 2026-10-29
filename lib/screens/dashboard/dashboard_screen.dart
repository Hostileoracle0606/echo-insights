import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../logic/relative_time.dart';
import '../../models/notebook.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notebooks_provider.dart';
import '../../providers/supabase_provider.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

// Matches the iPhone's display corner radius so the docked button's curvature
// echoes the screen's rounded corners. Flutter exposes no API for the real
// value (it's a private iOS metric); ~55pt approximates recent iPhones. On a
// ~58px-tall button this exceeds half the height, so it resolves to a stadium.
const double _displayCornerRadius = 55;

/// The post-login landing (editorial): a big animated welcome hero filling the
/// top half — black type with an amber period accent, the words sliding in
/// staggered on load — over the user's notebooks grouped by when they were
/// started, with a full-width "New notebook" button docked at the bottom.
/// Today / This week / Earlier, by the session's start date in the user's
/// local day. started_at arrives in UTC: compared as UTC, an evening session
/// west of UTC fell on "tomorrow" and dropped out of Today.
@visibleForTesting
String notebookGroup(DateTime startedAt, DateTime now) {
  final localNow = now.toLocal();
  final local = startedAt.toLocal();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return 'Today';
  if (now.difference(startedAt).inDays < 7) return 'This week';
  return 'Earlier';
}

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lumenColors;
    final name = ref.watch(displayNameProvider);
    final notebooks = ref.watch(notebooksProvider);

    return Scaffold(
      backgroundColor: colors.paper,
      body: SafeArea(
        child: notebooks.when(
          loading: () => Center(
            child: CircularProgressIndicator(color: colors.amber),
          ),
          error: (_, __) => _message(
            colors,
            "Couldn't load your notebooks.\n"
            'Check your connection and try again.',
          ),
          data: (list) {
            final isEmpty = list.isEmpty;
            final greeting = isEmpty
                ? (name.isEmpty
                    ? 'Welcome to Lumen'
                    : 'Welcome to Lumen, $name')
                : (name.isEmpty ? 'Welcome back' : 'Welcome back, $name');
            final totalEntities =
                list.fold<int>(0, (sum, nb) => sum + nb.entityCount);
            final subtitle = isEmpty
                ? null
                : '${list.length} ${list.length == 1 ? 'session' : 'sessions'}'
                    ' · $totalEntities ${totalEntities == 1 ? 'entity' : 'entities'}';

            // Big hero crowns the top; notebooks scroll below it; New is docked.
            return Column(
              children: [
                _AnimatedHero(
                  greeting: greeting,
                  subtitle: subtitle,
                  colors: colors,
                ),
                Expanded(
                  child: isEmpty
                      ? _emptyHint(colors)
                      : _cardsList(context, colors, list),
                ),
                _dock(context, ref, colors),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _cardsList(
    BuildContext context,
    LumenColors colors,
    List<Notebook> list,
  ) {
    final now = DateTime.now();
    final groups = <String, List<Notebook>>{};
    for (final notebook in list) {
      groups
          .putIfAbsent(
              notebookGroup(notebook.startedAt, now), () => <Notebook>[])
          .add(notebook);
    }

    final children = <Widget>[];
    for (final label in const ['Today', 'This week', 'Earlier']) {
      final group = groups[label];
      if (group == null || group.isEmpty) continue;
      children.add(_sectionLabel(label, colors));
      children.addAll(group.map((nb) => _card(context, nb, colors)));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 14),
      children: children,
    );
  }

  Widget _emptyHint(LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
      child: Text(
        'Each conversation becomes a notebook.\n'
        'Tap New notebook below to start your first.',
        style: TextStyle(
          fontFamily: LumenText.sansFontFamily,
          fontSize: 14,
          height: 1.5,
          color: colors.mutedForeground,
        ),
      ),
    );
  }

  Widget _sectionLabel(String label, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 10),
      child: Text(
        label.toUpperCase(),
        style: LumenText.eyebrow(colors.mutedForeground),
      ),
    );
  }

  Widget _card(BuildContext context, Notebook notebook, LumenColors colors) {
    final live = notebook.endedAt == null;
    final entityWord = notebook.entityCount == 1 ? 'entity' : 'entities';
    final when = live ? 'live now' : relativeTime(notebook.startedAt);
    final summary = notebook.summary?.trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.go('/notebook/${notebook.id}'),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.border),
            ),
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (live) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: colors.amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        notebook.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontSize: 18),
                      ),
                    ),
                  ],
                ),
                if (summary != null && summary.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 13,
                      height: 1.45,
                      color: colors.ink,
                    ),
                  ),
                ],
                const SizedBox(height: 9),
                Text(
                  '$when · ${notebook.entityCount} $entityWord',
                  style: TextStyle(
                    fontFamily: LumenText.sansFontFamily,
                    fontSize: 12,
                    color: colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The full-width "New notebook" block docked at the bottom. Its corner radius
  // matches the display's curvature; thick enough to read as a stadium.
  Widget _dock(BuildContext context, WidgetRef ref, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: _NewNotebookButton(colors: colors),
    );
  }

  Widget _message(LumenColors colors, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: LumenText.sansFontFamily,
            fontSize: 14,
            height: 1.5,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

/// The docked "New notebook" button. Owns its own creating/loading state so a
/// double-tap can't fire two inserts: while [createNotebook] is in flight the
/// button ignores taps and swaps its icon+label for a small spinner. On
/// success it hands off straight into a live recording session; on failure
/// (no signed-in user / RLS) it surfaces a snackbar instead of silently no-op.
class _NewNotebookButton extends ConsumerStatefulWidget {
  final LumenColors colors;

  const _NewNotebookButton({required this.colors});

  @override
  ConsumerState<_NewNotebookButton> createState() => _NewNotebookButtonState();
}

class _NewNotebookButtonState extends ConsumerState<_NewNotebookButton> {
  bool _creating = false;

  Future<void> _createAndOpen() async {
    if (_creating) return;
    setState(() => _creating = true);

    Notebook? notebook;
    try {
      notebook = await ref.read(supabaseServiceProvider).createNotebook();
    } catch (_) {
      notebook = null;
    }
    if (!mounted) return;

    if (notebook == null) {
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't create a notebook — check your connection."),
        ),
      );
      return;
    }

    // Fresh notebook: hand off straight into a live recording session.
    context.go('/notebook/${notebook.id}?start=true');
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Material(
      color: colors.ink,
      borderRadius: BorderRadius.circular(_displayCornerRadius),
      child: InkWell(
        key: const Key('newNotebookButton'),
        borderRadius: BorderRadius.circular(_displayCornerRadius),
        onTap: _creating ? null : _createAndOpen,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 19),
          alignment: Alignment.center,
          child: _creating
              ? SizedBox(
                  width: 19,
                  height: 19,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.paper,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 19, color: colors.paper),
                    const SizedBox(width: 6),
                    Text(
                      'New notebook',
                      style: TextStyle(
                        fontFamily: LumenText.sansFontFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: colors.paper,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// The editorial hero: a "Lumen." logotype and the greeting stacked one word per
/// line, each word sliding up + fading in staggered on load, in black with an
/// amber period that gently pulses. Fills whatever box the parent gives it.
class _AnimatedHero extends StatefulWidget {
  final String greeting;
  final String? subtitle;
  final LumenColors colors;

  const _AnimatedHero({
    required this.greeting,
    required this.subtitle,
    required this.colors,
  });

  @override
  State<_AnimatedHero> createState() => _AnimatedHeroState();
}

class _AnimatedHeroState extends State<_AnimatedHero>
    with TickerProviderStateMixin {
  // One-shot staggered entrance.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward();

  // Gentle looping pulse for the amber periods (triangle wave, 0..1..0).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  // Reveal curve for slot [i] of [total]: each eases in slightly after the last.
  Animation<double> _reveal(int i, int total) {
    const span = 0.55;
    final start = total <= 1 ? 0.0 : (i / (total - 1)) * (1.0 - span);
    return CurvedAnimation(
      parent: _intro,
      curve: Interval(start, start + span, curve: Curves.easeOutCubic),
    );
  }

  Widget _slide(Animation<double> anim, Widget child) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        final v = anim.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 24),
            child: child,
          ),
        );
      },
    );
  }

  // The amber period, alpha pulsing with [_pulse].
  Widget _period(TextStyle? style) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Text(
        '.',
        style: style?.copyWith(
          color:
              widget.colors.amber.withValues(alpha: 0.4 + 0.6 * _pulse.value),
        ),
      ),
    );
  }

  Widget _accentBar(Animation<double> anim) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) => Container(
        width: 54 * anim.value.clamp(0.0, 1.0),
        height: 4,
        decoration: BoxDecoration(
          color: widget.colors.amber,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final theme = Theme.of(context).textTheme;
    final words = widget.greeting.split(' ');
    final eyebrowStyle =
        theme.headlineMedium?.copyWith(fontSize: 15, color: colors.ink);
    final titleStyle = theme.headlineMedium
        ?.copyWith(fontSize: 78, height: 0.98, color: colors.ink);

    // Slots: eyebrow + each word + a trailing slot (accent + subtitle).
    final total = words.length + 2;
    var slot = 0;

    final lines = <Widget>[
      _slide(
        _reveal(slot++, total),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text('Lumen', style: eyebrowStyle), _period(eyebrowStyle)],
        ),
      ),
      const SizedBox(height: 16),
    ];

    for (var i = 0; i < words.length; i++) {
      final isLast = i == words.length - 1;
      lines.add(
        _slide(
          _reveal(slot++, total),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: isLast
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(words[i], style: titleStyle),
                      _period(titleStyle),
                    ],
                  )
                : Text(words[i], style: titleStyle, maxLines: 1),
          ),
        ),
      );
    }

    final tail = _reveal(slot, total);
    lines.add(const SizedBox(height: 18));
    lines.add(_accentBar(tail));
    if (widget.subtitle != null) {
      lines.add(const SizedBox(height: 12));
      lines.add(
        _slide(
          tail,
          Text(
            widget.subtitle!,
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 13,
              color: colors.mutedForeground,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }
}

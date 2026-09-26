import 'dart:async';
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../logic/entity_highlighter.dart';
import '../../logic/turn_state.dart' show Speaker;
import '../../models/entity.dart';
import '../../providers/journal_provider.dart';
import '../../providers/session_provider.dart';
import '../../theme/lumen_colors.dart';
import 'entity_note_sheet.dart';
import 'graph_canvas.dart';
import 'graph_drawer.dart';
import 'journal_top_bar.dart';
import 'transcript_page.dart';
import 'voice_dock.dart';

class JournalScreen extends ConsumerStatefulWidget {
  final String? notebookId;
  // When true, starts a live voice session as soon as the notebook (freshly
  // created via the dashboard's "New notebook" button) has finished loading.
  final bool autoStart;

  const JournalScreen({super.key, this.notebookId, this.autoStart = false});

  @override
  ConsumerState<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends ConsumerState<JournalScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // Graph or transcript behind the dock. The dock's outer buttons flip it;
  // [_page] runs the page transition between them (0 graph → 1 transcript).
  JournalView _view = JournalView.graph;
  late final AnimationController _page = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 580),
    reverseDuration: const Duration(milliseconds: 420),
  );
  bool _leaving = false;

  // Highlight terms, rebuilt only when the graph's entity map changes.
  Map<String, Entity>? _termsSource;
  List<HighlightTerm> _terms = const [];

  // Drives the graph sidepane (opened from the top-bar hamburger).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleNotebookEntry();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _page.dispose();
    super.dispose();
  }

  // The warm standby holds a live socket and a runtime credential. iOS
  // suspends sockets in the background anyway, so release it there and
  // prepare a fresh one on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final notifier = ref.read(journalProvider.notifier);
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        notifier.noteInteraction();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(notifier.coolDown());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant JournalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notebookId != widget.notebookId ||
        oldWidget.autoStart != widget.autoStart) {
      _scheduleNotebookEntry();
    }
  }

  void _scheduleNotebookEntry() {
    final id = widget.notebookId;
    if (id == null) return;
    final autoStart = widget.autoStart;
    // Provider state cannot be mutated during initState/build. The provider
    // owns the whole transition so loading and optional startup cannot race.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || widget.notebookId != id) return;
      final result = await ref
          .read(journalProvider.notifier)
          .enterNotebook(id, autoStart: autoStart);
      if (!mounted || widget.notebookId != id || result.succeeded) return;
      _showTransitionError(result);
    });
  }

  // Sidepane row tap: close the drawer, then open the entity note sheet over
  // the screen. Uses the State's (stable) context, not the drawer subtree's.
  void _openEntity(String entityId) {
    _scaffoldKey.currentState?.closeDrawer();
    showEntityNoteSheet(context, entityId);
  }

  Future<void> _toggleMic(SessionStatus status) async {
    // The tap registers before any network work: a light tick now, and the
    // dock morphs to "Lumen · Connecting" in the same frame.
    unawaited(HapticFeedback.lightImpact());
    final notifier = ref.read(journalProvider.notifier);
    late final NotebookTransitionResult result;
    if (status == SessionStatus.idle || status == SessionStatus.error) {
      result = await notifier.startSession();
    } else {
      result = await notifier.endSession();
    }
    if (mounted && !result.succeeded) _showTransitionError(result);
  }

  Future<void> _endSession() async {
    unawaited(HapticFeedback.lightImpact());
    final result = await ref.read(journalProvider.notifier).endSession();
    if (mounted && !result.succeeded) _showTransitionError(result);
  }

  void _setView(JournalView view) {
    if (view == _view) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _view = view);
    if (view == JournalView.transcript) {
      _page.forward();
    } else {
      _page.reverse();
    }
  }

  List<HighlightTerm> _termsFor(Map<String, Entity> entities) {
    if (!identical(entities, _termsSource)) {
      _termsSource = entities;
      _terms = termsForEntities(entities.values);
    }
    return _terms;
  }

  Future<void> _leaveToDashboard() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    final result = await ref.read(journalProvider.notifier).leaveNotebook();
    if (!mounted) return;
    if (result.succeeded) {
      context.go('/dashboard');
      return;
    }
    setState(() => _leaving = false);
    _showTransitionError(result);
  }

  void _showTransitionError(NotebookTransitionResult result) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? 'The notebook transition failed.'),
      ),
    );
  }

  // Map the session lifecycle onto dock modes. Connecting reads as "thinking"
  // (booting up); a live session reads as "speaking" while Lumen's audio is
  // still playing (the player's clock, not chunk arrival), "thinking" until
  // Lumen's opening has been heard, and "listening" the rest of the time;
  // everything else collapses to the static idle pill.
  DockMode _dockMode(
    SessionStatus status,
    bool agentSpeaking,
    bool openingInProgress,
  ) {
    switch (status) {
      case SessionStatus.connecting:
        // A cold start plays Lumen's greeting while the socket connects.
        return agentSpeaking ? DockMode.speaking : DockMode.thinking;
      case SessionStatus.live:
        if (agentSpeaking) return DockMode.speaking;
        // Live but Lumen's opening hasn't played yet: the mic is gated, so
        // "listening" would be a lie — keep the booting-up state.
        if (openingInProgress) return DockMode.thinking;
        return DockMode.listening;
      case SessionStatus.idle:
      case SessionStatus.ending:
      case SessionStatus.error:
        return DockMode.idle;
    }
  }

  // The provider keeps role/text rows in spoken order. Anything the user said
  // is a "you" turn, everything else is Lumen. Unfinished utterances render as
  // pending in their own slot.
  TranscriptTurn _toTurn(TranscriptRow row) => TranscriptTurn(
        row.turn.role == Speaker.user ? DockSpeaker.you : DockSpeaker.lumen,
        row.turn.text,
        id: row.turn.turnId,
        pending: row.pending,
        at: DateTime.tryParse(row.turn.startedAt),
      );

  // The graph recedes as the page rises: it shrinks a touch, blurs and fades
  // over the first 420ms, and stops ticking once fully covered.
  Widget _graphLayer(Widget graph) {
    return AnimatedBuilder(
      animation: _page,
      child: graph,
      builder: (context, child) {
        final t = Curves.easeOut.transform(
          const Interval(0, 420 / 580).transform(_page.value),
        );
        final covered = _page.value >= 1;
        return TickerMode(
          enabled: !covered,
          child: Offstage(
            offstage: covered,
            child: IgnorePointer(
              ignoring: t > 0,
              child: Opacity(
                opacity: 1 - t,
                child: Transform.scale(
                  scale: 1 - 0.06 * t,
                  child: ImageFiltered(
                    enabled: t > 0 && t < 1,
                    imageFilter: ImageFilter.blur(sigmaX: 6 * t, sigmaY: 6 * t),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // The transcript rises from under the dock like a page turned up: a
  // decelerating slide with its top corners squaring off as it lands.
  Widget _transcriptLayer(Widget page) {
    final slide = CurvedAnimation(
      parent: _page,
      curve: const Interval(60 / 580, 1, curve: Cubic(0.2, 0.9, 0.1, 1)),
      reverseCurve: Curves.easeInCubic,
    );
    return AnimatedBuilder(
      animation: _page,
      child: page,
      builder: (context, child) {
        if (_page.isDismissed) return const SizedBox.shrink();
        final colors = context.lumenColors;
        final radius = lerpDouble(28, 0, slide.value)!;
        return FractionalTranslation(
          translation: Offset(0, 1 - slide.value),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
              boxShadow: [
                BoxShadow(
                  color: colors.ink.withValues(alpha: 0.16 * (1 - slide.value)),
                  blurRadius: 50,
                  offset: const Offset(0, -18),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
              child: ColoredBox(color: colors.paper, child: child),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(journalProvider);
    final status = ref.watch(sessionStatusProvider);
    final liveUser = ref.watch(liveUserTextProvider);
    final liveAgent = ref.watch(liveAgentTextProvider);
    final extracting = ref.watch(extractingProvider);
    final openingInProgress = ref.watch(openingInProgressProvider);
    final activity = ref.watch(upsertActivityProvider);
    final muted = ref.watch(mutedProvider);
    final agentSpeaking = ref.watch(agentSpeakingProvider);
    final turns =
        ref.watch(transcriptRowsProvider).map(_toTurn).toList(growable: false);
    final terms = _termsFor(state.entities);
    final liveSpeaker = agentSpeaking || openingInProgress
        ? DockSpeaker.lumen
        : status == SessionStatus.live
            ? DockSpeaker.you
            : null;
    final sessionActive =
        status == SessionStatus.live || status == SessionStatus.connecting;
    final insets = MediaQuery.paddingOf(context);
    final relationCount =
        state.relations.values.where((relation) => relation.isActive).length;

    // Any touch means someone is here: refill the warm-up budget so a notebook
    // that went cold while idle is ready again by the time they reach the mic.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) =>
          ref.read(journalProvider.notifier).noteInteraction(),
      // In transcript view the back gesture returns to the graph first.
      child: PopScope(
        canPop: _view == JournalView.graph,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _setView(JournalView.graph);
        },
        child: Scaffold(
          key: _scaffoldKey,
          drawer: GraphDrawer(onEntityTap: _openEntity),
          body: Stack(
            fit: StackFit.expand,
            children: [
              _graphLayer(GraphCanvas(state: state)),
              _transcriptLayer(
                TranscriptPage(
                  turns: turns,
                  terms: terms,
                  entrance: _page,
                  liveSpeaker: liveSpeaker,
                  topInset: insets.top + 68,
                  // Dock (~108) + its 28pt lift + a breath.
                  bottomInset: insets.bottom + 28 + 108 + 8,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: JournalTopBar(
                      entityCount: state.entities.length,
                      relationCount: relationCount,
                      onMenuTap: () => _scaffoldKey.currentState?.openDrawer(),
                      onHomeTap: _leaving ? null : _leaveToDashboard,
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 28),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: VoiceDock(
                        mode:
                            _dockMode(status, agentSpeaking, openingInProgress),
                        liveUser: liveUser,
                        liveAgent: liveAgent,
                        extracting: extracting,
                        openingInProgress: openingInProgress,
                        activity: activity,
                        muted: muted,
                        view: _view,
                        terms: terms,
                        onMicTap: () => _toggleMic(status),
                        onViewChanged: _setView,
                        onMuteTap: () =>
                            ref.read(journalProvider.notifier).toggleMute(),
                        onEndTap: sessionActive ? _endSession : null,
                      ),
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

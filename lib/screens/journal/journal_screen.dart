import 'dart:async';
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../logic/entity_highlighter.dart';
import '../../logic/turn_state.dart' show Speaker, TurnInput;
import '../../models/entity.dart';
import '../../providers/journal_provider.dart';
import '../../providers/session_provider.dart';
import '../../theme/lumen_colors.dart';
import 'composer.dart';
import 'entity_note_sheet.dart';
import 'graph_canvas.dart';
import 'graph_drawer.dart';
import 'journal_top_bar.dart';
import 'lumen_joining.dart';
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
  // The page's slide curve, built once: a CurvedAnimation registers a status
  // listener on [_page], so it must be disposed rather than rebuilt per frame.
  late final CurvedAnimation _slide = CurvedAnimation(
    parent: _page,
    curve: const Interval(60 / 580, 1, curve: Cubic(0.2, 0.9, 0.1, 1)),
    reverseCurve: Curves.easeInCubic,
  );
  bool _leaving = false;

  // The composer fills the pill while the user types; the mic stays paused
  // until its own mic button switches back to voice.
  bool _composing = false;

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
    _slide.dispose();
    _page.dispose();
    super.dispose();
  }

  // The mic can't record in the background, and iOS suspends the socket
  // there: pause, and let the user resume on return (the connection comes
  // back by resumption handle if it lapsed).
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(ref.read(journalProvider.notifier).pauseMic());
      case AppLifecycleState.resumed:
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
      // Lumen failing to join has its own banner with Retry.
      if (ref.read(joiningPhaseProvider) != JoiningPhase.none) return;
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
    // The mic starts, pauses and resumes; only End ends the session.
    final notifier = ref.read(journalProvider.notifier);
    final NotebookTransitionResult result;
    switch (status) {
      case SessionStatus.idle:
      case SessionStatus.error:
        result = await notifier.startSession();
      case SessionStatus.live:
        await notifier.pauseMic();
        return;
      case SessionStatus.paused:
        result = await notifier.resumeMic();
      case SessionStatus.connecting:
      case SessionStatus.ending:
        return;
    }
    if (mounted && !result.succeeded) _showTransitionError(result);
  }

  Future<void> _retryJoining() async {
    unawaited(HapticFeedback.lightImpact());
    await ref.read(journalProvider.notifier).retryJoining();
  }

  Future<void> _endSession() async {
    unawaited(HapticFeedback.lightImpact());
    final result = await ref.read(journalProvider.notifier).endSession();
    if (mounted && !result.succeeded) _showTransitionError(result);
  }

  void _openComposer() {
    unawaited(HapticFeedback.selectionClick());
    setState(() => _composing = true);
    unawaited(ref.read(journalProvider.notifier).pauseMic());
  }

  Future<void> _closeComposer() async {
    unawaited(HapticFeedback.lightImpact());
    setState(() => _composing = false);
    final result = await ref.read(journalProvider.notifier).resumeMic();
    if (mounted && !result.succeeded) _showTransitionError(result);
  }

  bool _sendTyped(String text) {
    final sent = ref.read(journalProvider.notifier).sendTypedTurn(text);
    if (sent) unawaited(HapticFeedback.lightImpact());
    return sent;
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
        // A new notebook plays Lumen's greeting while the socket connects;
        // continuing one, the mic is already recording.
        if (agentSpeaking) return DockMode.speaking;
        return openingInProgress ? DockMode.thinking : DockMode.listening;
      case SessionStatus.live:
        if (agentSpeaking) return DockMode.speaking;
        // Live but Lumen's opening hasn't played yet: the mic is gated, so
        // "listening" would be a lie — keep the booting-up state.
        if (openingInProgress) return DockMode.thinking;
        return DockMode.listening;
      case SessionStatus.paused:
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
        typed: row.turn.input == TurnInput.typed,
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
    final slide = _slide;
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
    final reconnecting = ref.watch(reconnectingProvider);
    final joining = ref.watch(joiningPhaseProvider);
    final turns =
        ref.watch(transcriptRowsProvider).map(_toTurn).toList(growable: false);
    final terms = _termsFor(state.entities);
    final liveSpeaker = agentSpeaking || openingInProgress
        ? DockSpeaker.lumen
        : status == SessionStatus.live
            ? DockSpeaker.you
            : null;
    final sessionActive = status == SessionStatus.live ||
        status == SessionStatus.connecting ||
        status == SessionStatus.paused;
    final insets = MediaQuery.paddingOf(context);
    // Typing needs a session to send into; it ends when the session does.
    final typeable =
        status == SessionStatus.live || status == SessionStatus.paused;
    ref.listen(sessionStatusProvider, (_, next) {
      if (_composing &&
          next != SessionStatus.live &&
          next != SessionStatus.paused) {
        setState(() => _composing = false);
      }
    });
    final composing = _composing && typeable;
    // The keyboard lifts only the pill; the graph and the page stay put.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final dockBottom = keyboard > 0 ? keyboard + 8 : insets.bottom + 28;
    final relationCount =
        state.relations.values.where((relation) => relation.isActive).length;

    // In transcript view the back gesture returns to the graph first.
    return PopScope(
      canPop: _view == JournalView.graph,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setView(JournalView.graph);
      },
      child: Scaffold(
        key: _scaffoldKey,
        resizeToAvoidBottomInset: false,
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
                // Dock (~108) + its lift + a breath.
                bottomInset: dockBottom + 108 + 8,
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
                    muted: muted,
                    onMuteTap: () =>
                        ref.read(journalProvider.notifier).toggleMute(),
                    onEndTap: sessionActive ? _endSession : null,
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: keyboard,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: keyboard == 0,
                child: Padding(
                  padding: EdgeInsets.only(bottom: keyboard > 0 ? 8 : 28),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: VoiceDock(
                      // Lumen answering a typed turn still holds the floor,
                      // though the mic is paused.
                      mode: composing && agentSpeaking
                          ? DockMode.speaking
                          : _dockMode(status, agentSpeaking, openingInProgress),
                      liveUser: liveUser,
                      liveAgent: liveAgent,
                      extracting: extracting,
                      openingInProgress: openingInProgress,
                      // Typing is not a paused session.
                      paused: status == SessionStatus.paused && !composing,
                      reconnecting: reconnecting,
                      activity: activity,
                      view: _view,
                      terms: terms,
                      onMicTap: () => _toggleMic(status),
                      onViewChanged: _setView,
                      onTypeTap: typeable ? _openComposer : null,
                      composer: composing
                          ? Composer(
                              onSend: _sendTyped,
                              onVoiceTap: _closeComposer,
                              onViewChanged: _setView,
                              view: _view,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            // A new notebook waits for Lumen behind this cover.
            IgnorePointer(
              ignoring: joining != JoiningPhase.joining,
              child: AnimatedOpacity(
                opacity: joining == JoiningPhase.joining ? 1 : 0,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOut,
                child: const LumenJoiningCover(),
              ),
            ),
            if (joining == JoiningPhase.failed)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 68, 16, 0),
                    child: LumenJoinFailedBanner(
                      onRetry: _retryJoining,
                      onOpenWithoutVoice: () => unawaited(
                        ref.read(journalProvider.notifier).openWithoutVoice(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

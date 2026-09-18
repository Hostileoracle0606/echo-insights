import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../logic/turn_state.dart' show ConversationTurn, Speaker;
import '../../providers/journal_provider.dart';
import '../../providers/session_provider.dart';
import 'entity_note_sheet.dart';
import 'graph_canvas.dart';
import 'graph_drawer.dart';
import 'journal_top_bar.dart';
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

class _JournalScreenState extends ConsumerState<JournalScreen> {
  // The split-screen transcript panel. The dock's toggle and the dock morph
  // share this one flag, so it lives at the screen rather than inside the dock.
  bool _splitOpen = false;

  // Drives the graph sidepane (opened from the top-bar hamburger).
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    final id = widget.notebookId;
    if (id != null) {
      // Load the opened notebook's saved graph after the first frame (mutating
      // the provider during initState/build would throw). If this is a fresh
      // notebook, kick off the voice session right after the load completes —
      // openNotebook is async and initState can't await, so this closure runs
      // inside the post-frame callback instead.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await ref.read(journalProvider.notifier).openNotebook(id);
        if (!mounted) return;
        if (widget.autoStart) {
          await ref.read(journalProvider.notifier).startSession();
        }
      });
    }
  }

  // Sidepane row tap: close the drawer, then open the entity note sheet over
  // the screen. Uses the State's (stable) context, not the drawer subtree's.
  void _openEntity(String entityId) {
    _scaffoldKey.currentState?.closeDrawer();
    showEntityNoteSheet(context, entityId);
  }

  Future<void> _toggleMic(SessionStatus status) async {
    final notifier = ref.read(journalProvider.notifier);
    if (status == SessionStatus.idle || status == SessionStatus.error) {
      await notifier.startSession();
    } else {
      await notifier.endSession();
    }
  }

  // Map the session lifecycle onto dock modes. Connecting reads as "thinking"
  // (booting up); a live session reads as "speaking" while Lumen's audio is
  // playing and "listening" the rest of the time; everything else collapses
  // to the static idle pill.
  DockMode _dockMode(SessionStatus status, bool agentSpeaking) {
    switch (status) {
      case SessionStatus.connecting:
        return DockMode.thinking;
      case SessionStatus.live:
        return agentSpeaking ? DockMode.speaking : DockMode.listening;
      case SessionStatus.idle:
      case SessionStatus.ending:
      case SessionStatus.error:
        return DockMode.idle;
    }
  }

  // The provider keeps a flat role/text log; the dock speaks in DockTurns.
  // Anything the user said is a "you" bubble, everything else is Lumen.
  DockTurn _toTurn(ConversationTurn turn) => DockTurn(
        turn.role == Speaker.user ? DockSpeaker.you : DockSpeaker.lumen,
        turn.text,
      );

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(journalProvider);
    final status = ref.watch(sessionStatusProvider);
    final transcript = ref.watch(lastTranscriptProvider);
    final muted = ref.watch(mutedProvider);
    final agentSpeaking = ref.watch(agentSpeakingProvider);
    final turns =
        ref.watch(conversationProvider).map(_toTurn).toList(growable: false);
    final relationCount =
        state.relations.values.where((relation) => relation.isActive).length;

    return Scaffold(
      key: _scaffoldKey,
      drawer: GraphDrawer(onEntityTap: _openEntity),
      body: Stack(
        fit: StackFit.expand,
        children: [
          GraphCanvas(state: state),
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
                  onHomeTap: () => context.go('/dashboard'),
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
                    mode: _dockMode(status, agentSpeaking),
                    transcript: transcript,
                    muted: muted,
                    expanded: _splitOpen,
                    turns: turns,
                    onMicTap: () => _toggleMic(status),
                    onToggleSplit: () =>
                        setState(() => _splitOpen = !_splitOpen),
                    onMuteTap: () =>
                        ref.read(journalProvider.notifier).toggleMute(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

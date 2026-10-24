import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../logic/card_dates.dart';
import '../../logic/card_removals.dart';
import '../../logic/memory_removal.dart' show withoutEntity;
import '../../models/conversation_mode.dart';
import '../../models/entity.dart' show EntityType;
import '../../models/session_card.dart';
import '../../providers/export_provider.dart';
import '../../providers/journal_provider.dart' show removeUndoWindow;
import '../../providers/supabase_provider.dart';
import '../../services/markdown_export.dart';
import '../../services/notebook_commit_service.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import '../../widgets/context_tile.dart';
import '../../widgets/eyebrow.dart';
import '../../widgets/mode_header.dart';
import '../../widgets/result_card.dart';
import '../journal/voice_dock.dart';

enum _Phase { loading, ready, noCard, failed }

/// Where leaving a conversation lands (LM-16): the card it ended with.
///
/// The notebook is already left, so nothing here reads `journalProvider`:
/// the card, the notebook's revision and the user's removed entities (the
/// snapshot carries both) and the export are all fetched by [notebookId].
/// The screen never edits the card; removing an item removes it from memory.
class ClosingCardScreen extends ConsumerStatefulWidget {
  const ClosingCardScreen({super.key, required this.notebookId});

  final String notebookId;

  @override
  ConsumerState<ClosingCardScreen> createState() => _ClosingCardScreenState();
}

class _ClosingCardScreenState extends ConsumerState<ClosingCardScreen> {
  _Phase _phase = _Phase.loading;
  SessionCard? _card;
  Set<String> _suppressed = const {};

  // Bumped by Try again, so a slower earlier attempt can't land late.
  int _attempt = 0;

  late final CardRemovals _removals;
  ScaffoldMessengerState? _messenger;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoBar;

  bool _exporting = false;
  bool _exportFailed = false;

  @override
  void initState() {
    super.initState();
    final memory = ref.read(memoryControlServiceProvider);
    _removals = CardRemovals(
      remove: memory.removeEntity,
      window: removeUndoWindow,
      onFailed: _removalFailed,
    )..addListener(_rebuild);
    WidgetsBinding.instance.addObserver(_removals);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    // Its Undo would act on a screen that's gone; the removal is sent below.
    _undoBar?.close();
    WidgetsBinding.instance.removeObserver(_removals);
    _removals
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // ─── Loading ──────────────────────────────────────────────────────────────

  /// One close call per attempt (leaving usually started it already, and
  /// the service shares that request). A stored card that matches the
  /// notebook's revision shows first if it arrives before close returns.
  void _load() {
    final attempt = ++_attempt;
    final id = widget.notebookId;
    final cards = ref.read(sessionCardServiceProvider);
    final snapshot = _snapshot();
    final closing = cards.close(id);
    unawaited(_showStored(attempt, cards.load(id), snapshot));
    unawaited(_showClosed(attempt, closing, snapshot));
  }

  /// The notebook's snapshot, or null when it can't be read: the card still
  /// shows, without hiding already-removed items.
  Future<NotebookSnapshot?> _snapshot() async {
    try {
      return await ref
          .read(notebookCommitServiceProvider)
          .getNotebookSnapshot(widget.notebookId);
    } catch (error) {
      debugPrint('Closing card snapshot failed: $error');
      return null;
    }
  }

  bool _current(int attempt) => mounted && attempt == _attempt;

  Future<void> _showStored(
    int attempt,
    Future<SessionCard?> loading,
    Future<NotebookSnapshot?> snapshot,
  ) async {
    final SessionCard? stored;
    try {
      stored = await loading;
    } catch (error) {
      debugPrint('Stored closing card unreadable: $error');
      return;
    }
    final snap = await snapshot;
    if (stored == null || snap == null) return;
    if (stored.sourceRevision != snap.revision) return;
    if (!_current(attempt) || _phase != _Phase.loading) return;
    _show(stored, snap);
  }

  Future<void> _showClosed(
    int attempt,
    Future<SessionCard?> closing,
    Future<NotebookSnapshot?> snapshot,
  ) async {
    try {
      final card = await closing;
      final snap = await snapshot;
      if (!_current(attempt)) return;
      if (card == null) {
        if (_phase != _Phase.ready) setState(() => _phase = _Phase.noCard);
        return;
      }
      _show(card, snap);
    } catch (error) {
      debugPrint('Closing card failed: $error');
      // A current stored card is already showing: keep it.
      if (!_current(attempt) || _phase == _Phase.ready) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  void _show(SessionCard card, NotebookSnapshot? snapshot) {
    setState(() {
      _card = card;
      _suppressed = snapshot?.suppressedEntityIds ?? const {};
      _phase = switch (card.conversationMode) {
        ConversationMode.justTalk ||
        ConversationMode.weeklyDebrief =>
          _Phase.ready,
        // Their layouts come with LM-19 (prep) and LM-25 (first session).
        _ => _Phase.noCard,
      };
    });
  }

  void _tryAgain() {
    unawaited(HapticFeedback.lightImpact());
    setState(() => _phase = _Phase.loading);
    _load();
  }

  // ─── Actions ──────────────────────────────────────────────────────────────

  void _done() => context.go('/dashboard');

  void _talk() => context.go('/notebook/${widget.notebookId}?start=true');

  void _type() => context.go('/notebook/${widget.notebookId}?compose=true');

  void _view() => context.go('/notebook/${widget.notebookId}');

  Future<void> _confirmRemove(RememberItem item) async {
    final name = item.name;
    final pronoun = item.type == EntityType.person ? 'them' : 'it';
    final colors = context.lumenColors;
    const tapTarget = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(44, 44)),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove $name?'),
        content: Text(
          "Lumen will forget $name and won't add $pronoun back. "
          'What you said stays in your past conversations.',
        ),
        actions: [
          TextButton(
            style: tapTarget,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(44, 44),
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final id = item.entityId;
    _removals.remove(id);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final bar = _undoBar = messenger.showSnackBar(SnackBar(
      content: Text('Removed $name'),
      duration: removeUndoWindow,
      // An action would otherwise keep the bar up past the undo window.
      persist: false,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _removals.undo(id),
      ),
    ));
    unawaited(bar.closed.then((_) {
      if (identical(_undoBar, bar)) _undoBar = null;
    }));
  }

  void _removalFailed(String entityId) {
    final name = _card?.remember
            .where((item) => item.entityId == entityId)
            .firstOrNull
            ?.name ??
        'that';
    _messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text("Couldn't remove $name. Try again.")),
      );
  }

  /// "Export as Markdown": this notebook's vault, built from a fresh
  /// snapshot (minus anything inside its undo window), to the share sheet.
  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _exportFailed = false;
    });
    final share = ref.read(shareVaultProvider);
    try {
      final snapshot = await ref
          .read(notebookCommitServiceProvider)
          .getNotebookSnapshot(widget.notebookId);
      if (snapshot == null) throw StateError('Notebook not found');
      var state = snapshot.state;
      for (final id in state.entities.keys.toList()) {
        if (_removals.isHidden(id)) state = withoutEntity(state, id);
      }
      // Let the spinner paint before the synchronous build runs.
      await WidgetsBinding.instance.endOfFrame;
      await share(buildVault(state));
    } catch (error, stack) {
      debugPrint('Card export failed: $error\n$stack');
      if (mounted) setState(() => _exportFailed = true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _copyBullets(List<_Win> wins) async {
    final text = wins.map((win) => '• ${win.text}').join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    unawaited(HapticFeedback.selectionClick());
    if (!mounted) return;
    final count = wins.length;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Copied $count ${count == 1 ? 'win' : 'wins'}'),
      ));
  }

  // ─── Layout ───────────────────────────────────────────────────────────────

  String get _title => switch (_phase == _Phase.ready ? _card : null) {
        SessionCard(conversationMode: ConversationMode.weeklyDebrief) =>
          'Weekly debrief',
        SessionCard() => 'Just talk',
        null => 'Your conversation',
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final insets = MediaQuery.paddingOf(context);
    // Dock (~108) + its lift + a breath, as on the journal page.
    final bottomClearance = insets.bottom + 28 + 108 + 16;

    return Scaffold(
      backgroundColor: colors.paper,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ModeHeader(
                  title: _title,
                  onBack: _done,
                  trailing: _DoneButton(onTap: _done),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(20, 18, 20, bottomClearance),
                    child: _body(colors),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: VoiceDock(
                    onMicTap: _talk,
                    onTypeTap: _type,
                    onViewChanged: (_) => _view(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(LumenColors colors) {
    final card = _card;
    switch (_phase) {
      case _Phase.loading:
        return _StatusMessage(
          leading: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.mutedForeground,
            ),
          ),
          text: 'Writing your card…',
        );
      case _Phase.noCard:
        return const _StatusMessage(text: 'Your conversation is saved.');
      case _Phase.failed:
        return _StatusMessage(
          text: "Couldn't write your card. Your conversation is saved.",
          action: _TextAction(label: 'Try again', onTap: _tryAgain),
        );
      case _Phase.ready:
        return card!.conversationMode == ConversationMode.weeklyDebrief
            ? _debrief(card, colors)
            : _justTalk(card, colors);
    }
  }

  Widget _justTalk(SessionCard card, LumenColors colors) {
    final notes = card.notes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          eyebrow: shortDay(card.generatedAt.toLocal()),
          title: card.title,
          summary: card.summary,
        ),
        const SizedBox(height: 22),
        ResultCard(
          eyebrow: 'What you talked about',
          hero: notes.isEmpty
              ? null
              : ResultRow(badge: const ResultBadge.check(), text: notes.first),
          rows: [
            for (final note in notes.skip(1))
              ResultRow(badge: const ResultBadge.check(), text: note),
          ],
          footerNote:
              _exportFailed ? "Couldn't build the export. Try again." : null,
          footerActionLabel:
              _exporting ? 'Building export…' : 'Export as Markdown',
          onFooterAction: _exporting ? null : _export,
        ),
        ..._rememberList(card, colors),
      ],
    );
  }

  Widget _debrief(SessionCard card, LumenColors colors) {
    final day = card.generatedAt.toLocal();
    final wins = _Win.list(card.modeFields['wins']);
    final top = wins.where((win) => win.top).firstOrNull ?? wins.firstOrNull;
    final next = DateTime.tryParse('${card.modeFields['nextDebriefOn']}');
    final total = card.modeFields['briefTotal'];
    final opens = _OpenItem.list(card.modeFields['openItems']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          eyebrow: [
            shortDay(day),
            if (next != null) 'Next one ${monthDay(next)}',
          ].join(' · '),
          title: 'Added to your review brief',
          summary: card.summary,
        ),
        const SizedBox(height: 22),
        ResultCard(
          eyebrow: 'This week · ${wins.length} '
              '${wins.length == 1 ? 'win' : 'wins'}',
          hero: top == null
              ? null
              : ResultRow(
                  badge: const ResultBadge.check(),
                  label: 'Top win',
                  text: top.text,
                ),
          rows: [
            for (final win in wins)
              if (!identical(win, top))
                ResultRow(badge: const ResultBadge.check(), text: win.text),
          ],
          footerNote:
              total is num ? '${total.toInt()} wins in your brief' : null,
          footerActionLabel: wins.isEmpty ? null : 'Copy bullets',
          onFooterAction: wins.isEmpty ? null : () => _copyBullets(wins),
        ),
        ..._rememberList(card, colors, opens: [
          for (final open in opens)
            ContextItem(
              title: open.text,
              note: open.due == null ? null : askWhen(day, open.due!),
              open: true,
              removable: false,
            ),
        ]),
      ],
    );
  }

  /// "Lumen will remember": the card's items minus anything removed (before
  /// or on this screen), then [opens].
  List<Widget> _rememberList(
    SessionCard card,
    LumenColors colors, {
    List<ContextItem> opens = const [],
  }) {
    final visible = [
      for (final item in card.remember)
        if (!_suppressed.contains(item.entityId) &&
            !_removals.isHidden(item.entityId))
          item,
    ];
    final items = [
      for (final item in visible)
        ContextItem(
          title: item.name,
          note: [
            if (item.note case final note? when note.trim().isNotEmpty) note,
            if (item.isNew) 'new',
          ].join(' · ').nullIfEmpty,
          dotColor: LumenColors.entityColors[item.type],
        ),
    ];
    if (items.isEmpty && opens.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      ContextList(
        eyebrow: 'Lumen will remember',
        items: [...items, ...opens],
        onRemove: (tapped) {
          final index = items.indexOf(tapped);
          if (index >= 0) unawaited(_confirmRemove(visible[index]));
        },
      ),
    ];
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// One win from a debrief card's `wins`.
class _Win {
  const _Win(this.text, this.top);

  final String text;
  final bool top;

  static List<_Win> list(Object? data) => [
        if (data is List)
          for (final win in data)
            if (win is Map && win['text'] is String)
              _Win(win['text'] as String, win['top'] == true),
      ];
}

/// One of a debrief card's `openItems.created`.
class _OpenItem {
  const _OpenItem(this.text, this.due);

  final String text;
  final DateTime? due;

  static List<_OpenItem> list(Object? data) {
    final created = data is Map ? data['created'] : null;
    return [
      if (created is List)
        for (final item in created)
          if (item is Map && item['text'] is String)
            _OpenItem(
              item['text'] as String,
              DateTime.tryParse('${item['dueOn']}'),
            ),
    ];
  }
}

/// The day eyebrow, the serif title ending on an amber period, and the
/// summary.
class _Heading extends StatelessWidget {
  const _Heading({
    required this.eyebrow,
    required this.title,
    required this.summary,
  });

  final String eyebrow;
  final String title;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final bare = title.trimRight().replaceFirst(RegExp(r'\.+$'), '');
    // A title that ends on ? or ! keeps its own mark.
    final period = !bare.endsWith('?') && !bare.endsWith('!');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(eyebrow),
        const SizedBox(height: 10),
        Text.rich(
          TextSpan(
            text: bare,
            children: [
              if (period)
                TextSpan(text: '.', style: TextStyle(color: colors.amber)),
            ],
          ),
          style: LumenText.display(size: 32, height: 1.12, color: colors.ink),
        ),
        const SizedBox(height: 10),
        Text(
          summary,
          style: TextStyle(
            fontFamily: LumenText.sansFontFamily,
            fontSize: 15,
            height: 1.45,
            color: colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

/// Loading, saved and failed: one calm line, an optional action.
class _StatusMessage extends StatelessWidget {
  const _StatusMessage({this.leading, required this.text, this.action});

  final Widget? leading;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Text(
                  text,
                  style: LumenText.display(
                    size: 22,
                    height: 1.3,
                    color: colors.ink,
                  ),
                ),
              ),
            ],
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      _TextAction(label: 'Done', onTap: onTap);
}

/// A 44pt text button in ink, labelled for VoiceOver.
class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: colors.ink,
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: LumenText.sansFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

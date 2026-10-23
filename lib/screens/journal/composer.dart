import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';
import 'voice_dock.dart' show JournalView;

/// The typed-turn composer: what the pill shows in place of its button row
/// once Type is tapped (the prototype's Type screen).
///
///  * Quick replies ride on top, one tap each. The list comes from the mode;
///    Just talk has none.
///  * Below them, one row: the mic (back to voice), the view button, the
///    text field and an ink Send button. Send is disabled while the field
///    is empty; Return sends too.
///  * A sent message clears the field and keeps the keyboard up for the
///    next one, as a chat would.
///
/// Like the pill, it only reads its props and calls back.
class Composer extends StatefulWidget {
  /// Sends [text]; returns whether it was accepted. Accepted text leaves the
  /// field, refused text stays to try again.
  final bool Function(String text) onSend;

  /// Closes the composer and resumes voice.
  final VoidCallback onVoiceTap;

  /// Asks for the other view; null leaves the slot empty.
  final ValueChanged<JournalView>? onViewChanged;
  final JournalView view;

  /// Ready-made replies above the field, e.g. "Same as last week".
  final List<String> quickReplies;

  /// Focus the field (and raise the keyboard) as the composer opens.
  final bool autofocus;

  const Composer({
    super.key,
    required this.onSend,
    required this.onVoiceTap,
    this.onViewChanged,
    this.view = JournalView.graph,
    this.quickReplies = const [],
    this.autofocus = true,
  });

  /// The quick-reply row, for tests.
  @visibleForTesting
  static const Key quickRepliesKey = ValueKey('composer-quick-replies');

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  static const double _target = 44;

  final _controller = TextEditingController();
  final _focus = FocusNode();

  bool get _canSend => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Rebuild only when sendability flips, not on every keystroke.
    var could = _canSend;
    _controller.addListener(() {
      if (_canSend != could) setState(() => could = _canSend);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    if (!_canSend) return;
    if (widget.onSend(_controller.text)) _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final onView = widget.onViewChanged;
    final graph = widget.view == JournalView.graph;
    final replies = widget.quickReplies;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replies.isNotEmpty)
            Padding(
              key: Composer.quickRepliesKey,
              padding: const EdgeInsets.only(bottom: 4),
              child: SizedBox(
                height: _target,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: replies.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => _QuickReply(
                    label: replies[i],
                    colors: colors,
                    onTap: () => widget.onSend(replies[i]),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              _RoundButton(
                label: 'Switch to voice',
                icon: Icons.mic,
                fill: colors.amber,
                iconColor: Colors.white,
                onTap: widget.onVoiceTap,
              ),
              const SizedBox(width: 6),
              if (onView == null)
                const SizedBox(width: _target, height: _target)
              else
                _RoundButton(
                  label: graph ? 'Show transcript' : 'Show graph',
                  icon: graph ? Icons.article_outlined : Icons.hub_outlined,
                  iconColor: colors.ink,
                  onTap: () => onView(
                    graph ? JournalView.transcript : JournalView.graph,
                  ),
                ),
              const SizedBox(width: 6),
              Expanded(child: _field(colors)),
              const SizedBox(width: 8),
              _RoundButton(
                label: 'Send',
                icon: Icons.arrow_upward_rounded,
                fill: _canSend ? colors.ink : colors.ink.withValues(alpha: 0.18),
                iconColor: colors.card,
                onTap: _canSend ? _send : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(LumenColors colors) {
    final text = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 15,
      height: 20 / 15,
      color: colors.ink,
    );
    final edge = OutlineInputBorder(
      borderRadius: BorderRadius.circular(_target / 2),
      borderSide: BorderSide(color: colors.border),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _target),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        minLines: 1,
        maxLines: 4,
        // Return sends rather than adding a line.
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.send,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) => _send(),
        // Keep the keyboard up after sending, for the next message.
        onEditingComplete: () {},
        style: text,
        cursorColor: colors.amber,
        decoration: InputDecoration(
          hintText: 'Type to Lumen',
          hintStyle: text.copyWith(color: colors.mutedForeground),
          isDense: true,
          filled: true,
          fillColor: colors.paper,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: edge,
          enabledBorder: edge,
          focusedBorder: edge.copyWith(
            borderSide: BorderSide(color: colors.ink.withValues(alpha: 0.4)),
          ),
        ),
      ),
    );
  }
}

/// A 44pt circular button. Null [onTap] disables it.
class _RoundButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color? fill;
  final Color iconColor;
  final VoidCallback? onTap;

  const _RoundButton({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: fill == null
              ? null
              : BoxDecoration(color: fill, shape: BoxShape.circle),
          child: Icon(icon, size: 19, color: iconColor),
        ),
      ),
    );
  }
}

/// One quick reply: a paper chip, 44pt tall.
class _QuickReply extends StatelessWidget {
  final String label;
  final LumenColors colors;
  final VoidCallback onTap;

  const _QuickReply({
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
        child: Container(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: colors.paper,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: colors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

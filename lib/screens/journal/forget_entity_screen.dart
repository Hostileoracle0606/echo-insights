import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';

/// LM-49: the confirmation for "Forget [name]". Lists what will be removed,
/// from the server's own count (`forget_entity_preview`), before anything is
/// deleted. Pops `true` once the person is forgotten.
class ForgetEntityScreen extends ConsumerStatefulWidget {
  const ForgetEntityScreen({
    super.key,
    required this.entityId,
    required this.name,
  });

  final String entityId;
  final String name;

  @override
  ConsumerState<ForgetEntityScreen> createState() => _ForgetEntityScreenState();
}

class _ForgetEntityScreenState extends ConsumerState<ForgetEntityScreen> {
  late Future<ForgetPreview> _preview = _load();
  bool _forgetting = false;
  bool _failed = false;

  Future<ForgetPreview> _load() =>
      ref.read(memoryControlServiceProvider).previewForget(widget.entityId);

  Future<void> _forget() async {
    setState(() {
      _forgetting = true;
      _failed = false;
    });
    // The reason stays generic: it reaches the system prompt, so no name.
    final passed = await requireReauth(context, reason: 'Forget this person');
    if (!mounted) return;
    if (!passed) {
      // A failed or cancelled check forgets nothing.
      setState(() => _forgetting = false);
      return;
    }
    try {
      await ref
          .read(journalProvider.notifier)
          .forgetEntity(widget.entityId, name: widget.name);
      ref.invalidate(notebooksProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // No detail: errors never carry what was forgotten.
      if (mounted) {
        setState(() {
          _forgetting = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Scaffold(
      appBar: AppBar(title: Text('Forget ${widget.name}?')),
      body: SafeArea(
        child: FutureBuilder<ForgetPreview>(
          future: _preview,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _message(
                "Couldn't check what would be removed. Try again.",
                colors,
                retry: () => setState(() => _preview = _load()),
              );
            }
            final preview = snapshot.data;
            if (preview == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return _content(preview, colors);
          },
        ),
      ),
    );
  }

  Widget _message(String text, LumenColors colors, {VoidCallback? retry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.mutedForeground)),
            if (retry != null)
              TextButton(onPressed: retry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }

  List<String> _lines(ForgetPreview p) {
    final name = widget.name;
    String n(int count, String one, String many) =>
        '$count ${count == 1 ? one : many}';
    return [
      '$name on your map, in ${n(p.notebooks, 'conversation', 'conversations')}',
      if (p.relations > 0)
        n(p.relations, 'connection to something else',
            'connections to other things'),
      if (p.followUps + p.askedQuestions > 0)
        n(p.followUps + p.askedQuestions, 'question Lumen would ask about $name',
            'questions Lumen would ask about $name'),
      if (p.cards > 0)
        '$name\'s name in ${n(p.cards, 'conversation card', 'conversation cards')}, '
            'replaced with "someone"',
      if (p.briefDeleted) 'Your briefing for next time, which mentions $name',
    ];
  }

  Widget _content(ForgetPreview preview, LumenColors colors) {
    final name = widget.name;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Text('THIS WILL REMOVE', style: LumenText.eyebrow(colors.mutedForeground)),
        const SizedBox(height: 10),
        for (final line in _lines(preview))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: TextStyle(color: colors.mutedForeground)),
                Expanded(
                  child: Text(line,
                      style: TextStyle(fontSize: 15, height: 1.4, color: colors.ink)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Text(
          "Lumen won't bring $name up again, or add them back if you use "
          'that name later. A nickname or a first name alone can slip '
          'through. Your past conversations keep your words for you to read; '
          'Lumen reads them with the name replaced.',
          style: TextStyle(fontSize: 13, height: 1.4, color: colors.mutedForeground),
        ),
        if (_failed) ...[
          const SizedBox(height: 12),
          Text("Couldn't forget $name. Try again.",
              style: TextStyle(color: colors.destructive)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: colors.destructive,
            foregroundColor: colors.destructiveForeground,
          ),
          onPressed: _forgetting ? null : _forget,
          child: _forgetting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text('Forget $name'),
        ),
        const SizedBox(height: 8),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed:
              _forgetting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

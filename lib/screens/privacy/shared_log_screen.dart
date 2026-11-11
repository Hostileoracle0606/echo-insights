import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/shared_log_provider.dart';
import '../../services/shared_log.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// Opens [SharedLogScreen] for one session, or for every session when
/// [notebookId] is null (from the privacy sheet).
Future<void> showSharedLog(BuildContext context, {String? notebookId}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => SharedLogScreen(notebookId: notebookId),
    ),
  );
}

/// "What Lumen shared" (LM-57): each request sent to the text model, newest
/// first, with the exact text that was sent. The log lives only on this
/// phone and keeps 7 days.
class SharedLogScreen extends ConsumerStatefulWidget {
  const SharedLogScreen({super.key, this.notebookId});

  final String? notebookId;

  @override
  ConsumerState<SharedLogScreen> createState() => _SharedLogScreenState();
}

class _SharedLogScreenState extends ConsumerState<SharedLogScreen> {
  late final Future<List<SharedRequest>> _entries = _load();

  Future<List<SharedRequest>> _load() {
    final log = ref.read(sharedLogProvider);
    final id = widget.notebookId;
    // Reading sweeps what is older than 7 days.
    return id == null ? log.readAll() : log.read(id);
  }

  static String _when(DateTime at) {
    final t = at.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    return '${months[t.month - 1]} ${t.day}, ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final body = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 15,
      height: 1.45,
      color: colors.ink,
    );
    final small = body.copyWith(fontSize: 13, color: colors.mutedForeground);
    return Scaffold(
      backgroundColor: colors.paper,
      appBar: AppBar(
        backgroundColor: colors.paper,
        elevation: 0,
        title: const Text('What Lumen shared'),
        leading: IconButton(
          key: const Key('sharedLogClose'),
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back, color: colors.ink),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<List<SharedRequest>>(
          future: _entries,
          builder: (context, snapshot) {
            final entries = snapshot.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  'The text Lumen sent to its text model, as it left your '
                  'phone, with the names of people, places and '
                  'organizations it recognized swapped for made-up ones. '
                  'Kept on this phone for 7 days. Never uploaded.',
                  style: body,
                ),
                const SizedBox(height: 8),
                Text(
                  "Your live voice conversation isn't swapped and isn't "
                  'logged here.',
                  key: const Key('sharedLogVoiceNote'),
                  style: small,
                ),
                const SizedBox(height: 16),
                if (entries == null && !snapshot.hasError)
                  const Center(child: CircularProgressIndicator())
                else if (entries == null || entries.isEmpty)
                  Text(
                    'Nothing to show. Requests appear here after a '
                    'conversation.',
                    key: const Key('sharedLogEmpty'),
                    style: small,
                  )
                else
                  for (final entry in entries)
                    _Entry(
                      entry: entry,
                      when: _when(entry.at),
                      body: body,
                      small: small,
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.entry,
    required this.when,
    required this.body,
    required this.small,
  });

  final SharedRequest entry;
  final String when;
  final TextStyle body;
  final TextStyle small;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return ExpansionTile(
      key: Key('sharedLogEntry-${entry.at.toUtc().toIso8601String()}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: colors.ink,
      collapsedIconColor: colors.ink,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Text(entry.kind.label, style: body),
      subtitle: Text(
        entry.carriesRealNames ? '$when · contains a real name' : when,
        style: small,
      ),
      children: [
        if (entry.carriesRealNames)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'This request holds the real opening line, with names as you '
              'said them, so it is read aloud right.',
              key: const Key('sharedLogRealNameNote'),
              style: small.copyWith(color: colors.destructive),
            ),
          ),
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(entry.body),
          style: small.copyWith(
            fontFamily: 'Menlo',
            color: colors.ink,
          ),
        ),
      ],
    );
  }
}

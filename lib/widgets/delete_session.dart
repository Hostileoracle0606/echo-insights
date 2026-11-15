import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/journal_provider.dart';
import '../providers/notebooks_provider.dart';
import '../providers/opening_prep_provider.dart';
import '../providers/shared_log_provider.dart';
import '../providers/supabase_provider.dart';
import '../security/app_lock_provider.dart';
import '../theme/lumen_colors.dart';

/// "Delete this session" (LM-48), shared by the closing card and the
/// dashboard's notebook menu: confirms, deletes through
/// [SessionDeletionService], drops what the app holds for the notebook and
/// lands on the dashboard. Nothing the session held is logged. Face ID or
/// the passcode comes after the confirmation; a failed or cancelled check
/// deletes nothing.
Future<void> confirmAndDeleteSession(
  BuildContext context,
  WidgetRef ref,
  String notebookId,
) async {
  final colors = context.lumenColors;
  const tapTarget = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(44, 44)),
  );
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete this session?'),
      content: const Text(
        'This deletes the conversation, its card, and what Lumen remembered '
        'only from it. Anything your other conversations also mention stays. '
        'Notes pulled from it can stay in a short-lived cache for about a '
        "week. You can't undo this.",
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
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (!await requireReauth(context, reason: 'Delete this session')) return;
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  try {
    await ref.read(sessionDeletionServiceProvider).deleteSession(notebookId);
  } catch (error) {
    // The type only: the message could carry what the session held.
    debugPrint('Delete session failed: ${error.runtimeType}');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
            content: Text("Couldn't delete the session. Try again.")),
      );
    return;
  }

  // The screen that asked is unmounted by the navigation, so take what is
  // needed from [ref] first.
  final prep = ref.read(openingPrepProvider);
  // The crash-recovery copy on this phone. The session is gone either way,
  // so nothing waits for this.
  unawaited(
    ref
        .read(turnJournalServiceProvider)
        .forgetNotebook(notebookId)
        .catchError((Object error) {
      debugPrint('Clearing the turn journal failed: ${error.runtimeType}');
    }),
  );
  // What Lumen shared about it (LM-57) goes with the session.
  unawaited(
    ref.read(sharedLogProvider).forgetNotebook(notebookId).catchError(
      (Object error) {
        debugPrint('Clearing the shared log failed: ${error.runtimeType}');
      },
    ),
  );
  ref.read(cardDrafterProvider).stop(notebookId);
  ref.invalidate(notebooksProvider);
  ref.invalidate(journalProvider);
  router.go('/dashboard');
  // The brief written from this session is gone; reload what the next
  // opening reads.
  await prep.refresh();
}

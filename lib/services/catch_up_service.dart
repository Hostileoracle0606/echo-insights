import 'dart:collection';

import 'unfinished_work_service.dart';

/// One unit of launch-time catch-up (LM-103). Plain values keyed by ids and
/// revisions, never by text, so a plan can be logged and compared.
sealed class CatchUpStep {
  const CatchUpStep();

  /// The notebook the step belongs to; null for account-wide work (erase).
  String? get notebookId;
}

/// Commit every journalled turn of [notebookId], in journal order, without
/// opening it (see `HeadlessTurnFinisher.finishNotebook`).
class FinishTurnsStep extends CatchUpStep {
  const FinishTurnsStep({required this.notebookId});

  @override
  final String notebookId;

  @override
  bool operator ==(Object other) =>
      other is FinishTurnsStep && other.notebookId == notebookId;

  @override
  int get hashCode => Object.hash(FinishTurnsStep, notebookId);

  @override
  String toString() => 'FinishTurnsStep($notebookId)';
}

/// Make the card for [notebookId] at [revision] (status first: a card
/// already present at that revision means nothing to do).
class CardStep extends CatchUpStep {
  const CardStep({
    required this.notebookId,
    required this.revision,
    this.cardRevision,
    this.draft = false,
  });

  @override
  final String notebookId;
  final int revision;
  final int? cardRevision;
  final bool draft;

  @override
  bool operator ==(Object other) =>
      other is CardStep &&
      other.notebookId == notebookId &&
      other.revision == revision &&
      other.cardRevision == cardRevision &&
      other.draft == draft;

  @override
  int get hashCode =>
      Object.hash(CardStep, notebookId, revision, cardRevision, draft);

  @override
  String toString() => 'CardStep($notebookId, r$revision)';
}

/// Make the brief from [notebookId] at [revision].
class BriefStep extends CatchUpStep {
  const BriefStep({required this.notebookId, required this.revision});

  @override
  final String notebookId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is BriefStep &&
      other.notebookId == notebookId &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(BriefStep, notebookId, revision);

  @override
  String toString() => 'BriefStep($notebookId, r$revision)';
}

/// Build the [missing] search vectors of [notebookId].
class VectorsStep extends CatchUpStep {
  const VectorsStep({
    required this.notebookId,
    required this.entityCount,
    required this.missing,
  });

  @override
  final String notebookId;
  final int entityCount;
  final int missing;

  @override
  bool operator ==(Object other) =>
      other is VectorsStep &&
      other.notebookId == notebookId &&
      other.entityCount == entityCount &&
      other.missing == missing;

  @override
  int get hashCode =>
      Object.hash(VectorsStep, notebookId, entityCount, missing);

  @override
  String toString() => 'VectorsStep($notebookId, $missing missing)';
}

/// Run erase job [jobId] from batch [nextBatch] on, one numbered batch at a
/// time (`forget_erase_batch`).
class EraseStep extends CatchUpStep {
  const EraseStep({required this.jobId, required this.nextBatch});

  final String jobId;
  final int nextBatch;

  @override
  String? get notebookId => null;

  @override
  bool operator ==(Object other) =>
      other is EraseStep &&
      other.jobId == jobId &&
      other.nextBatch == nextBatch;

  @override
  int get hashCode => Object.hash(EraseStep, jobId, nextBatch);

  @override
  String toString() => 'EraseStep($jobId, batch $nextBatch)';
}

/// An ordered catch-up plan.
class CatchUpPlan {
  const CatchUpPlan({
    required this.steps,
    this.truncated = false,
  });

  final List<CatchUpStep> steps;

  /// The server listed at most 50 notebooks per kind; more remain for the
  /// next catch-up.
  final bool truncated;

  bool get isEmpty => steps.isEmpty;

  /// Committing turns moves a notebook's revision, so the card (and brief)
  /// the server listed before may be for an older revision, and a notebook
  /// whose turns only lived on this phone was not listed at all. After the
  /// turn steps, read `get_unfinished_work()` again and plan once more.
  bool get replanAfterTurns => steps.any((step) => step is FinishTurnsStep);

  List<CatchUpStep> stepsFor(String notebookId) => [
        for (final step in steps)
          if (step.notebookId == notebookId) step,
      ];
}

/// Orders catch-up work. Pure: no I/O, no clock.
abstract final class CatchUpPlanner {
  /// The open notebook first (its turns, then card, brief, vectors), then
  /// every other notebook with work, each kept together in the same order,
  /// newest first; erase jobs last.
  ///
  /// "Newest first" without timestamps: [journalNotebookIds] (newest turn
  /// first, from `TurnJournalService.listNotebookIdsWithTurns`) come first,
  /// since their words exist only on this phone, then notebooks in the order
  /// the server lists them (cards, briefs, vectors; each newest first).
  static CatchUpPlan plan({
    required String? openNotebookId,
    required List<String> journalNotebookIds,
    required UnfinishedWork serverWork,
  }) {
    final order = <String>[
      if (openNotebookId != null) openNotebookId,
      ...journalNotebookIds,
      for (final card in serverWork.cards) card.notebookId,
      for (final brief in serverWork.briefs) brief.notebookId,
      for (final vectors in serverWork.vectors) vectors.notebookId,
    ];
    final journal = journalNotebookIds.toSet();

    final steps = <CatchUpStep>[];
    for (final notebookId in LinkedHashSet<String>.from(order)) {
      if (journal.contains(notebookId)) {
        steps.add(FinishTurnsStep(notebookId: notebookId));
      }
      for (final card in serverWork.cards) {
        if (card.notebookId != notebookId) continue;
        steps.add(CardStep(
          notebookId: notebookId,
          revision: card.revision,
          cardRevision: card.cardRevision,
          draft: card.draft,
        ));
      }
      for (final brief in serverWork.briefs) {
        if (brief.notebookId != notebookId) continue;
        steps.add(BriefStep(notebookId: notebookId, revision: brief.revision));
      }
      for (final vectors in serverWork.vectors) {
        if (vectors.notebookId != notebookId) continue;
        steps.add(VectorsStep(
          notebookId: notebookId,
          entityCount: vectors.entityCount,
          missing: vectors.missing,
        ));
      }
    }
    for (final job in serverWork.erase) {
      steps.add(EraseStep(jobId: job.jobId, nextBatch: job.nextBatch));
    }
    return CatchUpPlan(steps: steps, truncated: serverWork.truncated);
  }
}

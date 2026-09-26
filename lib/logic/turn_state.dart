/// Finalized-turn extraction state model — Flutter port.
///
/// This mirrors `src/lib/turn-state/reducer.ts` rule for rule. The two
/// platforms deliberately share one domain model so web and iOS cannot drift
/// into contradicting each other about what a turn is or when it may write to
/// the graph. Platform adapters (audio capture, playback, HTTP, storage) stay
/// separate; only the rules are duplicated, and they are duplicated exactly.
///
/// The invariant both ports protect:
///
///   Only an immutable finalized transcript may modify the canonical graph,
///   and one finalized transcript produces at most one durable turn.
library;

enum Speaker { user, assistant }

/// Durable checkpoint stages. Persisted, so a restart resumes rather than repeats.
enum DurableStage { finalRecorded, extracted, commitPending, committed, failed }

enum _AssistantTranscriptGate {
  accepting,
  discardingInterruptedTurn,
  awaitingNextTurn,
}

const int _maxConversation = 16;
const int _provisionalMinChars = 6;

/// Full identity of an asynchronous operation. Every awaited result carries one
/// and must match the live turn on all five fields before it may change
/// anything. Cancellation is only a resource optimisation; this is the rule.
class TurnIdentity {
  const TurnIdentity({
    required this.sessionId,
    required this.notebookId,
    required this.turnId,
    required this.transcriptVersion,
    required this.generation,
  });

  final String sessionId;
  final String notebookId;
  final String turnId;
  final int transcriptVersion;
  final int generation;

  TurnIdentity copyWith({int? transcriptVersion, int? generation}) => TurnIdentity(
        sessionId: sessionId,
        notebookId: notebookId,
        turnId: turnId,
        transcriptVersion: transcriptVersion ?? this.transcriptVersion,
        generation: generation ?? this.generation,
      );
}

class ActiveTurn {
  ActiveTurn({
    required this.turnId,
    required this.speaker,
    required this.startedAt,
    this.text = '',
    this.transcriptVersion = 0,
    this.generation = 0,
    this.finalText,
    this.turnCompleted = false,
    this.heardChars,
    this.interrupted = false,
  });

  final String turnId;
  final Speaker speaker;
  final String startedAt;

  /// Replaceable display text. Superseded wholesale by each interim update.
  String text;
  int transcriptVersion;
  int generation;

  /// Authoritative text, if a final transcription arrived.
  String? finalText;
  bool turnCompleted;

  /// Assistant only: characters confirmed *played to the user*. `null` means
  /// the boundary is unknown, and an interrupted turn with an unknown boundary
  /// is never durably extracted.
  int? heardChars;
  bool interrupted;
}

/// An immutable finalized transcript plus its durable processing state.
/// [commitRequestId] is minted once and reused for every commit attempt of this
/// turn, including attempts after a revision conflict.
class FinalizedTurn {
  FinalizedTurn({
    required this.turnId,
    required this.sessionId,
    required this.notebookId,
    required this.speaker,
    required this.transcript,
    required this.transcriptVersion,
    required this.transcriptHash,
    required this.extractorVersion,
    required this.generation,
    required this.commitRequestId,
    required this.stage,
    required this.finalizedAt,
    this.extraction,
    this.baseRevision,
    this.revision,
    this.truncatedFromInterruption = false,
  });

  final String turnId;
  final String sessionId;
  final String notebookId;
  final Speaker speaker;
  final String transcript;
  final int transcriptVersion;
  final String transcriptHash;
  final String extractorVersion;
  final int generation;
  final String commitRequestId;
  final String finalizedAt;
  final bool truncatedFromInterruption;

  final DurableStage stage;
  final Map<String, dynamic>? extraction;
  final int? baseRevision;
  final int? revision;

  /// Returns a copy with the given fields changed.
  ///
  /// Deliberately copy-on-change rather than mutate-in-place: a `PersistTurn`
  /// effect must describe the turn *as it was when the effect was emitted*.
  /// With shared mutable records, a later stage change would retroactively
  /// rewrite an already-emitted checkpoint and the adapter would persist the
  /// wrong stage — which is exactly the ordering guarantee crash recovery
  /// depends on. The TypeScript port gets this for free from object spread.
  FinalizedTurn copyWith({
    DurableStage? stage,
    Map<String, dynamic>? extraction,
    int? baseRevision,
    int? revision,
  }) =>
      FinalizedTurn(
        turnId: turnId,
        sessionId: sessionId,
        notebookId: notebookId,
        speaker: speaker,
        transcript: transcript,
        transcriptVersion: transcriptVersion,
        transcriptHash: transcriptHash,
        extractorVersion: extractorVersion,
        generation: generation,
        commitRequestId: commitRequestId,
        stage: stage ?? this.stage,
        finalizedAt: finalizedAt,
        extraction: extraction ?? this.extraction,
        baseRevision: baseRevision ?? this.baseRevision,
        revision: revision ?? this.revision,
        truncatedFromInterruption: truncatedFromInterruption,
      );

  TurnIdentity get identity => TurnIdentity(
        sessionId: sessionId,
        notebookId: notebookId,
        turnId: turnId,
        transcriptVersion: transcriptVersion,
        generation: generation,
      );

  Map<String, dynamic> toJson() => {
        'turnId': turnId,
        'sessionId': sessionId,
        'notebookId': notebookId,
        'speaker': speaker.name,
        'transcript': transcript,
        'transcriptVersion': transcriptVersion,
        'transcriptHash': transcriptHash,
        'extractorVersion': extractorVersion,
        'generation': generation,
        'commitRequestId': commitRequestId,
        'stage': stage.name,
        'extraction': extraction,
        'baseRevision': baseRevision,
        'revision': revision,
        'finalizedAt': finalizedAt,
        'truncatedFromInterruption': truncatedFromInterruption,
      };

  static FinalizedTurn fromJson(Map<String, dynamic> json) => FinalizedTurn(
        turnId: json['turnId'] as String,
        sessionId: json['sessionId'] as String,
        notebookId: json['notebookId'] as String,
        speaker: Speaker.values.byName(json['speaker'] as String),
        transcript: json['transcript'] as String,
        transcriptVersion: json['transcriptVersion'] as int,
        transcriptHash: json['transcriptHash'] as String,
        extractorVersion: json['extractorVersion'] as String,
        generation: json['generation'] as int,
        commitRequestId: json['commitRequestId'] as String,
        stage: DurableStage.values.byName(json['stage'] as String),
        extraction: (json['extraction'] as Map?)?.cast<String, dynamic>(),
        baseRevision: json['baseRevision'] as int?,
        revision: json['revision'] as int?,
        finalizedAt: json['finalizedAt'] as String,
        truncatedFromInterruption: json['truncatedFromInterruption'] as bool? ?? false,
      );
}

class ConversationTurn {
  const ConversationTurn({
    required this.turnId,
    required this.role,
    required this.text,
    required this.createdAt,
    String? startedAt,
  }) : startedAt = startedAt ?? createdAt;

  final String turnId;
  final Speaker role;
  final String text;

  /// When the turn finalized.
  final String createdAt;

  /// When the utterance began (its first transcript chunk). Conversation order
  /// follows this, not [createdAt]: Gemini does not order a user's final
  /// transcription before the assistant's reply, so finalization order can
  /// put an answer above the line it answers.
  final String startedAt;
}

/// Orders ISO-8601 instants by time. Parsed rather than string-compared: the
/// web port writes millisecond precision and Dart writes microseconds.
int compareInstants(String a, String b) {
  final da = DateTime.tryParse(a);
  final db = DateTime.tryParse(b);
  if (da == null || db == null) return a.compareTo(b);
  return da.compareTo(db);
}

// ─── Events ────────────────────────────────────────────────────────────────

sealed class TurnEvent {
  const TurnEvent();
}

class SessionStarted extends TurnEvent {
  const SessionStarted({
    required this.sessionId,
    required this.notebookId,
    this.revision = 0,
  });
  final String sessionId;
  final String notebookId;
  final int revision;
}

class SessionEnded extends TurnEvent {
  const SessionEnded();
}

/// Replaces the active turn's display text wholesale.
class InterimTranscript extends TurnEvent {
  const InterimTranscript({required this.speaker, required this.text});
  final Speaker speaker;
  final String text;
}

/// Authoritative transcription. May arrive before or after [TurnCompleted].
class FinalTranscript extends TurnEvent {
  const FinalTranscript({required this.speaker, required this.text});
  final Speaker speaker;
  final String text;
}

class TurnCompleted extends TurnEvent {
  const TurnCompleted({required this.speaker, this.transcriptGeneration});
  final Speaker speaker;

  /// Identifies the assembler buffer parked while this turn awaits its final
  /// provider transcript. Null means there was no buffered transcript.
  final int? transcriptGeneration;
}

class FinalizationDeadline extends TurnEvent {
  const FinalizationDeadline({required this.speaker, required this.turnId});
  final Speaker speaker;
  final String turnId;
}

/// Assistant playback watermark: characters confirmed heard.
class PlaybackAdvanced extends TurnEvent {
  const PlaybackAdvanced({required this.heardChars});
  final int heardChars;
}

/// Barge-in. `heardChars == null` means the boundary could not be determined.
class AssistantInterrupted extends TurnEvent {
  const AssistantInterrupted({required this.heardChars});
  final int? heardChars;
}

class ProvisionalExtractionSettled extends TurnEvent {
  const ProvisionalExtractionSettled({required this.key, required this.entityNames});
  final TurnIdentity key;
  final List<String> entityNames;
}

class DurableExtractionSucceeded extends TurnEvent {
  const DurableExtractionSucceeded({required this.key, required this.payload});
  final TurnIdentity key;
  final Map<String, dynamic> payload;
}

class DurableExtractionFailed extends TurnEvent {
  const DurableExtractionFailed({required this.key, required this.message});
  final TurnIdentity key;
  final String message;
}

class CommitCommitted extends TurnEvent {
  const CommitCommitted({required this.turnId, required this.revision});
  final String turnId;
  final int revision;
}

class CommitConflict extends TurnEvent {
  const CommitConflict({required this.turnId, required this.currentRevision});
  final String turnId;
  final int currentRevision;
}

class SnapshotReloaded extends TurnEvent {
  const SnapshotReloaded({required this.revision});
  final int revision;
}

/// Transport failed after the request left; the outcome is genuinely unknown.
class CommitUnknown extends TurnEvent {
  const CommitUnknown({required this.turnId});
  final String turnId;
}

class CommitRejected extends TurnEvent {
  const CommitRejected({required this.turnId, required this.code});
  final String turnId;
  final String code;
}

/// Recovery: durable turns loaded from the turn journal at startup.
class Restored extends TurnEvent {
  const Restored({required this.turns});
  final List<FinalizedTurn> turns;
}

// ─── Effects ───────────────────────────────────────────────────────────────

sealed class TurnEffect {
  const TurnEffect();
}

class CancelExtraction extends TurnEffect {
  const CancelExtraction({required this.turnId, required this.generation});
  final String turnId;
  final int generation;
}

class StartProvisionalExtraction extends TurnEffect {
  const StartProvisionalExtraction({required this.key, required this.text});
  final TurnIdentity key;
  final String text;
}

class StartDurableExtraction extends TurnEffect {
  const StartDurableExtraction({required this.key, required this.transcript});
  final TurnIdentity key;
  final String transcript;
}

class StartCommit extends TurnEffect {
  const StartCommit({required this.turnId, required this.commitRequestId});
  final String turnId;
  final String commitRequestId;
}

class ReloadSnapshot extends TurnEffect {
  const ReloadSnapshot({required this.turnId});
  final String turnId;
}

class ScheduleFinalizationDeadline extends TurnEffect {
  const ScheduleFinalizationDeadline({
    required this.speaker,
    required this.turnId,
    this.transcriptGeneration,
  });
  final Speaker speaker;
  final String turnId;
  final int? transcriptGeneration;
}

class PersistTurn extends TurnEffect {
  const PersistTurn({required this.turn});
  final FinalizedTurn turn;
}

class ForgetTurn extends TurnEffect {
  const ForgetTurn({required this.turnId});
  final String turnId;
}

class FlushPlayback extends TurnEffect {
  const FlushPlayback();
}

// ─── State ─────────────────────────────────────────────────────────────────

class TurnMachineState {
  String? sessionId;
  String? notebookId;

  /// At most one in-progress (still collecting) turn per speaker.
  ActiveTurn? activeUser;
  ActiveTurn? activeAssistant;

  /// Turns marked complete that still await an authoritative transcription.
  /// Held separately so a following turn's interim text cannot displace a turn
  /// mid-finalization.
  ActiveTurn? awaitingUser;
  ActiveTurn? awaitingAssistant;

  /// Finalized turns awaiting or undergoing durable processing, in order.
  final List<FinalizedTurn> pending = [];

  /// Canonical conversation history. Finalized, actually-heard text only.
  final List<ConversationTurn> conversation = [];

  /// Display-only provisional preview.
  List<String>? previewEntityNames;
  String? previewTurnId;

  /// Observability: results rejected because their identity no longer matched.
  int staleRejections = 0;

  /// Last committed notebook revision the machine has observed.
  int revision = 0;
}

// ─── Machine ───────────────────────────────────────────────────────────────

/// Cuts [text] at the playback watermark without splitting a word. A
/// half-spoken word was not heard as that word, so it must not be extracted.
String truncateToHeard(String text, int heardChars) {
  if (heardChars >= text.length) return text;
  if (heardChars <= 0) return '';
  final slice = text.substring(0, heardChars);
  if (RegExp(r'\s').hasMatch(text[heardChars])) return slice.trimRight();
  final lastSpace = slice.lastIndexOf(RegExp(r'\s'));
  if (lastSpace <= 0) return '';
  return slice.substring(0, lastSpace).trimRight();
}

/// Stable, dependency-free content hash (FNV-1a). Proves which exact immutable
/// text produced an extraction.
String fnv1a(String text) {
  var h = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

class TurnMachine {
  TurnMachine({
    required String Function() now,
    required String Function() newTurnId,
    required String Function() newRequestId,
    this.extractorVersion = 'v1',
    this.provisionalExtraction = false,
  })  : _now = now,
        _newTurnId = newTurnId,
        _newRequestId = newRequestId;

  final String Function() _now;
  final String Function() _newTurnId;
  final String Function() _newRequestId;
  final String extractorVersion;
  final bool provisionalExtraction;

  final TurnMachineState state = TurnMachineState();

  /// In-memory only: prevents starting the same durable step twice.
  String? _inFlight;

  /// Assistant transcript gate after a barge-in. Gemini's documented sequence
  /// is `interrupted` then `turnComplete`, and output transcription has no
  /// ordering guarantee — text can still arrive for speech never played.
  _AssistantTranscriptGate _assistantGate = _AssistantTranscriptGate.accepting;

  ActiveTurn? _active(Speaker s) => s == Speaker.user ? state.activeUser : state.activeAssistant;
  ActiveTurn? _awaiting(Speaker s) =>
      s == Speaker.user ? state.awaitingUser : state.awaitingAssistant;

  void _setActive(Speaker s, ActiveTurn? t) {
    if (s == Speaker.user) {
      state.activeUser = t;
    } else {
      state.activeAssistant = t;
    }
  }

  void _setAwaiting(Speaker s, ActiveTurn? t) {
    if (s == Speaker.user) {
      state.awaitingUser = t;
    } else {
      state.awaitingAssistant = t;
    }
  }

  ActiveTurn _ensureActive(Speaker speaker) =>
      _active(speaker) ??
      ActiveTurn(
        turnId: _newTurnId(),
        speaker: speaker,
        startedAt: _now(),
        heardChars: speaker == Speaker.assistant ? 0 : null,
      );

  List<TurnEffect> _rejectStale() {
    state.staleRejections += 1;
    return const [];
  }

  /// Advances the head of the pending queue. Turns are processed strictly in
  /// their original order with one durable step in flight at a time — that
  /// ordering is what makes conflict replay deterministic and keeps mention
  /// counts from double-applying.
  List<TurnEffect> _driveQueue() {
    if (state.pending.isEmpty || _inFlight != null) return const [];
    final head = state.pending.first;

    if (head.stage == DurableStage.finalRecorded) {
      _inFlight = head.turnId;
      // The key carries the turn's OWN session, not whichever socket is open
      // now: a reconnect must not invalidate work already finalized.
      return [StartDurableExtraction(key: head.identity, transcript: head.transcript)];
    }
    if (head.stage == DurableStage.extracted) {
      _inFlight = head.turnId;
      // Record "about to commit, with this request id, against this revision"
      // BEFORE the durable write, so an unknown outcome can be retried
      // identically rather than guessed at.
      final updated = head.copyWith(
        stage: DurableStage.commitPending,
        baseRevision: state.revision,
      );
      state.pending[0] = updated;
      return [
        PersistTurn(turn: updated),
        StartCommit(turnId: updated.turnId, commitRequestId: updated.commitRequestId),
      ];
    }
    if (head.stage == DurableStage.commitPending) {
      _inFlight = head.turnId;
      return [StartCommit(turnId: head.turnId, commitRequestId: head.commitRequestId)];
    }
    return const [];
  }

  List<TurnEffect> _dropHead() {
    if (state.pending.isEmpty) return _driveQueue();
    final head = state.pending.removeAt(0);
    _inFlight = null;
    return [ForgetTurn(turnId: head.turnId), ..._driveQueue()];
  }

  /// Turns a completed active turn into an immutable finalized turn. The only
  /// path by which spoken text becomes eligible to change the canonical graph.
  List<TurnEffect> _finalize(ActiveTurn turn, String transcript, bool truncated) {
    final text = transcript.trim();
    if (_active(turn.speaker)?.turnId == turn.turnId) {
      _setActive(turn.speaker, null);
    }
    if (_awaiting(turn.speaker)?.turnId == turn.turnId) {
      _setAwaiting(turn.speaker, null);
    }
    if (text.isEmpty) return const [];

    final finalized = FinalizedTurn(
      turnId: turn.turnId,
      sessionId: state.sessionId!,
      notebookId: state.notebookId!,
      speaker: turn.speaker,
      transcript: text,
      transcriptVersion: turn.transcriptVersion,
      transcriptHash: fnv1a(text),
      extractorVersion: extractorVersion,
      // Advancing the generation invalidates any provisional work for this turn.
      generation: turn.generation + 1,
      commitRequestId: _newRequestId(),
      stage: DurableStage.finalRecorded,
      finalizedAt: _now(),
      truncatedFromInterruption: truncated,
    );

    final effects = <TurnEffect>[];
    if (turn.generation > 0) {
      effects.add(CancelExtraction(turnId: turn.turnId, generation: turn.generation));
    }
    state.pending.add(finalized);
    if (state.previewTurnId == turn.turnId) {
      state.previewTurnId = null;
      state.previewEntityNames = null;
    }
    final spoken = ConversationTurn(
      turnId: turn.turnId,
      role: turn.speaker,
      text: text,
      createdAt: finalized.finalizedAt,
      startedAt: turn.startedAt,
    );
    // Insert by utterance start; ties keep finalization order.
    var at = state.conversation.length;
    while (at > 0 &&
        compareInstants(state.conversation[at - 1].startedAt, spoken.startedAt) > 0) {
      at -= 1;
    }
    state.conversation.insert(at, spoken);
    if (state.conversation.length > _maxConversation) {
      state.conversation.removeRange(0, state.conversation.length - _maxConversation);
    }
    // The checkpoint is written BEFORE the expensive model call, so a restart
    // between here and extraction resumes instead of losing the turn.
    effects.add(PersistTurn(turn: finalized));
    return [...effects, ..._driveQueue()];
  }

  /// Utterances still being transcribed or awaiting their authoritative final,
  /// oldest first — display-only, never canonical. A consumer merging these
  /// with [TurnMachineState.conversation] by [ConversationTurn.startedAt] gets
  /// the conversation in the order it was spoken, with nothing vanishing
  /// between "the reply started" and "the user's final arrived".
  List<ConversationTurn> get inProgress {
    final turns = <ConversationTurn>[
      for (final turn in [
        state.awaitingUser,
        state.activeUser,
        state.awaitingAssistant,
        state.activeAssistant,
      ])
        if (turn != null && turn.text.trim().isNotEmpty)
          ConversationTurn(
            turnId: turn.turnId,
            role: turn.speaker,
            text: turn.text.trim(),
            createdAt: turn.startedAt,
            startedAt: turn.startedAt,
          ),
    ];
    turns.sort((a, b) => compareInstants(a.startedAt, b.startedAt));
    return turns;
  }

  List<TurnEffect> dispatch(TurnEvent event) {
    switch (event) {
      case SessionStarted():
        _assistantGate = _AssistantTranscriptGate.accepting;
        if (state.notebookId != null && state.notebookId == event.notebookId) {
          // Reconnecting to the SAME notebook. A live socket is session-scoped;
          // a finalized turn's durable work is notebook-scoped and stays valid.
          state.sessionId = event.sessionId;
          state.revision = event.revision;
          state.activeUser = null;
          state.activeAssistant = null;
          state.awaitingUser = null;
          state.awaitingAssistant = null;
          state.previewEntityNames = null;
          state.previewTurnId = null;
          return _driveQueue();
        }
        state.sessionId = event.sessionId;
        state.notebookId = event.notebookId;
        state.activeUser = null;
        state.activeAssistant = null;
        state.awaitingUser = null;
        state.awaitingAssistant = null;
        state.pending.clear();
        state.conversation.clear();
        state.previewEntityNames = null;
        state.previewTurnId = null;
        state.staleRejections = 0;
        state.revision = event.revision;
        _inFlight = null;
        return const [];

      case SessionEnded():
        state.activeUser = null;
        state.activeAssistant = null;
        state.awaitingUser = null;
        state.awaitingAssistant = null;
        state.previewEntityNames = null;
        state.previewTurnId = null;
        _assistantGate = _AssistantTranscriptGate.accepting;
        return const [];

      case InterimTranscript():
        if (state.sessionId == null) return const [];
        if (event.speaker == Speaker.assistant) {
          if (_assistantGate == _AssistantTranscriptGate.discardingInterruptedTurn) {
            return const [];
          }
          if (_assistantGate == _AssistantTranscriptGate.awaitingNextTurn) {
            _assistantGate = _AssistantTranscriptGate.accepting;
          }
        }
        final base = _ensureActive(event.speaker);
        // An authoritative final transcript already arrived; interim chatter
        // must not overwrite it.
        if (base.finalText != null) return const [];
        if (base.text == event.text) return const [];

        final startProvisional = provisionalExtraction &&
            event.speaker == Speaker.user &&
            event.text.trim().length >= _provisionalMinChars;
        final priorGeneration = base.generation;
        base.text = event.text;
        base.transcriptVersion += 1;
        if (startProvisional) base.generation += 1;
        _setActive(event.speaker, base);
        if (!startProvisional) return const [];

        final effects = <TurnEffect>[];
        if (priorGeneration > 0) {
          effects.add(CancelExtraction(turnId: base.turnId, generation: priorGeneration));
        }
        // Provisional extraction is display-only. Nothing it returns may reach
        // the canonical graph, persistence, mention counts, or follow-ups.
        effects.add(StartProvisionalExtraction(key: _keyOf(base), text: event.text));
        return effects;

      case FinalTranscript():
        if (state.sessionId == null) return const [];
        // Unheard text for an interrupted assistant turn never becomes durable.
        if (event.speaker == Speaker.assistant &&
            _assistantGate != _AssistantTranscriptGate.accepting) {
          return const [];
        }

        final waiting = _awaiting(event.speaker);
        if (waiting != null) {
          waiting.text = event.text;
          waiting.finalText = event.text;
          waiting.transcriptVersion += 1;
          return _finalize(waiting, event.text, waiting.interrupted);
        }
        final base = _ensureActive(event.speaker);
        base.text = event.text;
        base.finalText = event.text;
        base.transcriptVersion += 1;
        _setActive(event.speaker, base);
        return const [];

      case TurnCompleted():
        final active = _active(event.speaker);
        if (event.speaker == Speaker.assistant &&
            _assistantGate == _AssistantTranscriptGate.discardingInterruptedTurn) {
          _assistantGate = _AssistantTranscriptGate.awaitingNextTurn;
        }
        if (active == null) return const [];

        // Interrupted with an undeterminable heard boundary: we cannot prove
        // which words reached the user, so none of them may be extracted.
        if (active.interrupted && active.heardChars == null) {
          _setActive(event.speaker, null);
          return const [];
        }

        active.turnCompleted = true;
        _setActive(event.speaker, null);
        if (active.finalText != null) {
          return _finalize(active, active.finalText!, active.interrupted);
        }
        // No authoritative text yet. Park the turn and wait — but not forever.
        _setAwaiting(event.speaker, active);
        return [
          ScheduleFinalizationDeadline(
            speaker: event.speaker,
            turnId: active.turnId,
            transcriptGeneration: event.transcriptGeneration,
          ),
        ];

      case FinalizationDeadline():
        final waiting = _awaiting(event.speaker);
        // Already finalized by a late final transcript — no phantom turn.
        if (waiting == null || waiting.turnId != event.turnId) return const [];
        return _finalize(waiting, waiting.finalText ?? waiting.text, waiting.interrupted);

      case PlaybackAdvanced():
        final active = state.activeAssistant;
        if (active == null || active.interrupted) return const [];
        active.heardChars = event.heardChars;
        return const [];

      case AssistantInterrupted():
        final effects = <TurnEffect>[const FlushPlayback()];
        _assistantGate = _AssistantTranscriptGate.discardingInterruptedTurn;
        final active = state.activeAssistant;
        if (active == null) return effects;

        if (event.heardChars == null) {
          // Boundary unknown: mark it so turnCompleted discards the turn.
          active.interrupted = true;
          active.heardChars = null;
          active.finalText = null;
          return effects;
        }
        final heard = truncateToHeard(active.text, event.heardChars!);
        active.interrupted = true;
        active.heardChars = event.heardChars;
        active.text = heard;
        // Locking finalText here is what prevents later output transcription
        // from re-attaching the unheard tail.
        active.finalText = heard;
        active.transcriptVersion += 1;
        return effects;

      case ProvisionalExtractionSettled():
        final turn = _findActive(event.key.turnId);
        if (event.key.sessionId != state.sessionId ||
            event.key.notebookId != state.notebookId ||
            turn == null ||
            turn.transcriptVersion != event.key.transcriptVersion ||
            turn.generation != event.key.generation) {
          return _rejectStale();
        }
        // Display state only. Deliberately touches nothing else.
        state.previewTurnId = event.key.turnId;
        state.previewEntityNames = event.entityNames;
        return const [];

      case DurableExtractionSucceeded():
        if (state.pending.isEmpty) return _rejectStale();
        final head = state.pending.first;
        // All five identity fields must still match the turn at the head of the
        // queue, and that turn must belong to the notebook currently open.
        if (head.notebookId != state.notebookId ||
            head.turnId != event.key.turnId ||
            head.sessionId != event.key.sessionId ||
            head.notebookId != event.key.notebookId ||
            head.transcriptVersion != event.key.transcriptVersion ||
            head.generation != event.key.generation) {
          return _rejectStale();
        }
        _inFlight = null;
        // Store the result before committing: a restart here reuses it rather
        // than paying for — and possibly receiving a different — model result.
        final updated = head.copyWith(
          stage: DurableStage.extracted,
          extraction: event.payload,
        );
        state.pending[0] = updated;
        return [PersistTurn(turn: updated), ..._driveQueue()];

      case DurableExtractionFailed():
        if (state.pending.isEmpty) return _rejectStale();
        final head = state.pending.first;
        if (head.turnId != event.key.turnId || head.notebookId != event.key.notebookId) {
          return _rejectStale();
        }
        return _dropHead();

      case CommitCommitted():
        if (state.pending.isEmpty || state.pending.first.turnId != event.turnId) {
          return _rejectStale();
        }
        state.revision = event.revision;
        return _dropHead();

      case CommitConflict():
        if (state.pending.isEmpty || state.pending.first.turnId != event.turnId) {
          return _rejectStale();
        }
        // A conflict performed no write, so no ledger row exists and the same
        // request id stays valid. Hold the queue until the authoritative
        // snapshot is back, then replay every pending turn in original order.
        state.revision = event.currentRevision;
        return [ReloadSnapshot(turnId: event.turnId)];

      case SnapshotReloaded():
        state.revision = event.revision;
        _inFlight = null;
        if (state.pending.isNotEmpty) {
          state.pending[0] = state.pending.first.copyWith(baseRevision: event.revision);
        }
        return _driveQueue();

      case CommitUnknown():
        if (state.pending.isEmpty || state.pending.first.turnId != event.turnId) {
          return _rejectStale();
        }
        // Outcome genuinely unknown. Retry the identical commit with the same
        // request id: the server ledger replays the stored result if it already
        // committed, and applies it exactly once otherwise.
        _inFlight = null;
        return _driveQueue();

      case CommitRejected():
        if (state.pending.isEmpty || state.pending.first.turnId != event.turnId) {
          return _rejectStale();
        }
        return _dropHead();

      case Restored():
        final usable = event.turns.where((t) => t.stage != DurableStage.committed).toList();
        state.pending.insertAll(0, usable);
        return _driveQueue();
    }
  }

  TurnIdentity _keyOf(ActiveTurn turn) => TurnIdentity(
        sessionId: state.sessionId!,
        notebookId: state.notebookId!,
        turnId: turn.turnId,
        transcriptVersion: turn.transcriptVersion,
        generation: turn.generation,
      );

  ActiveTurn? _findActive(String turnId) {
    for (final turn in [
      state.activeUser,
      state.activeAssistant,
      state.awaitingUser,
      state.awaitingAssistant,
    ]) {
      if (turn != null && turn.turnId == turnId) return turn;
    }
    return null;
  }
}

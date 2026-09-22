import 'turn_state.dart';

/// A completed provider buffer that is still waiting for its authoritative
/// final transcription.
class _PendingTranscript {
  _PendingTranscript({required this.generation, required this.text});

  final int generation;
  final String text;
  bool expired = false;
}

/// Translates Gemini Live's raw transcript signals into turn-machine events.
///
/// Chunks only produce replaceable interim text. When a provider turn closes,
/// its buffer is parked until either the authoritative final chunk or the
/// finalization deadline arrives. Parking is essential because Gemini does not
/// guarantee whether `turnComplete` or the final transcript arrives first.
class TranscriptAssembler {
  String _userBuffer = '';
  String _assistantBuffer = '';
  bool _userTurnOpen = false;
  bool _userTurnClosed = false;
  bool _assistantInterrupted = false;
  int _nextGeneration = 0;
  final List<_PendingTranscript> _pendingUser = [];
  final List<_PendingTranscript> _pendingAssistant = [];

  /// Current assistant display text — the basis for the heard watermark.
  String get assistantText => _assistantBuffer;

  List<_PendingTranscript> _pendingFor(Speaker speaker) =>
      speaker == Speaker.user ? _pendingUser : _pendingAssistant;

  int? _park(Speaker speaker) {
    final text = speaker == Speaker.user ? _userBuffer : _assistantBuffer;
    if (speaker == Speaker.user) {
      _userBuffer = '';
    } else {
      _assistantBuffer = '';
    }
    if (text.trim().isEmpty) return null;
    final pending = _PendingTranscript(
      generation: ++_nextGeneration,
      text: text,
    );
    _pendingFor(speaker).add(pending);
    return pending.generation;
  }

  /// A new chunk proves a newer turn has begun, so an expired placeholder for
  /// a final that never arrived must not consume this turn's future final.
  void _discardExpiredBeforeNewTurn(Speaker speaker) {
    _pendingFor(speaker).removeWhere((pending) => pending.expired);
  }

  List<TurnEvent>? _resolvePendingFinal(Speaker speaker, String chunk) {
    final queue = _pendingFor(speaker);
    if (queue.isEmpty) return null;
    final pending = queue.first;
    if (pending.expired) {
      queue.removeAt(0);
      final activeText =
          speaker == Speaker.user ? _userBuffer : _assistantBuffer;
      // If a newer turn already has text, this final belongs to that turn.
      // Without active text it is the delayed final governed by the expired
      // placeholder and must be discarded.
      return activeText.isEmpty ? const [] : null;
    }
    queue.removeAt(0);
    final text = '${pending.text}$chunk';
    if (text.trim().isEmpty) return const [];
    return [FinalTranscript(speaker: speaker, text: text)];
  }

  /// The assistant answering is the signal that the user's turn is over.
  List<TurnEvent> _closeUserTurnIfNeeded() {
    if (!_userTurnOpen || _userTurnClosed) return const [];
    _userTurnClosed = true;
    return [
      TurnCompleted(
        speaker: Speaker.user,
        transcriptGeneration: _park(Speaker.user),
      ),
    ];
  }

  List<TurnEvent> userChunk(String chunk) {
    if (chunk.isEmpty) return const [];
    _discardExpiredBeforeNewTurn(Speaker.user);
    _userBuffer += chunk;
    _userTurnOpen = true;
    return [InterimTranscript(speaker: Speaker.user, text: _userBuffer)];
  }

  /// Provider interim transcription: replaces the buffer, never appends.
  List<TurnEvent> userInterim(String text) {
    _discardExpiredBeforeNewTurn(Speaker.user);
    _userBuffer = text;
    _userTurnOpen = true;
    return [InterimTranscript(speaker: Speaker.user, text: _userBuffer)];
  }

  /// Final ("finished") user transcription chunk; closes the transcript.
  List<TurnEvent> userFinal(String chunk) {
    final pending = _resolvePendingFinal(Speaker.user, chunk);
    if (pending != null) return pending;

    _userBuffer += chunk;
    final text = _userBuffer;
    _userBuffer = '';
    _userTurnOpen = true;
    if (text.trim().isEmpty) return const [];
    return [FinalTranscript(speaker: Speaker.user, text: text)];
  }

  List<TurnEvent> assistantChunk(String chunk) {
    if (chunk.isEmpty || _assistantInterrupted) return const [];
    _discardExpiredBeforeNewTurn(Speaker.assistant);
    final closing = _closeUserTurnIfNeeded();
    _assistantBuffer += chunk;
    return [
      ...closing,
      InterimTranscript(speaker: Speaker.assistant, text: _assistantBuffer),
    ];
  }

  List<TurnEvent> assistantFinal(String chunk) {
    final pending = _resolvePendingFinal(Speaker.assistant, chunk);
    if (pending != null) return pending;
    if (_assistantInterrupted) return const [];

    final closing = _closeUserTurnIfNeeded();
    _assistantBuffer += chunk;
    final text = _assistantBuffer;
    _assistantBuffer = '';
    if (text.trim().isEmpty) return closing;
    return [
      ...closing,
      FinalTranscript(speaker: Speaker.assistant, text: text)
    ];
  }

  List<TurnEvent> turnComplete() {
    final events = <TurnEvent>[..._closeUserTurnIfNeeded()];
    final assistantGeneration =
        _assistantInterrupted ? null : _park(Speaker.assistant);
    if (_assistantInterrupted) _assistantBuffer = '';
    events.add(TurnCompleted(
      speaker: Speaker.assistant,
      transcriptGeneration: assistantGeneration,
    ));
    _resetActive();
    return events;
  }

  List<TurnEvent> interrupted(int? heardChars) {
    _assistantInterrupted = true;
    if (_assistantBuffer.trim().isNotEmpty) {
      final pending = _PendingTranscript(
        generation: ++_nextGeneration,
        text: _assistantBuffer,
      )..expired = true;
      _pendingAssistant.add(pending);
    }
    _assistantBuffer = '';
    return [AssistantInterrupted(heardChars: heardChars)];
  }

  /// Marks exactly the buffer governed by a fired fallback deadline. Keeping
  /// the placeholder until the next provider signal lets a late final be
  /// discarded instead of becoming a duplicate turn.
  void expirePending(Speaker speaker, int generation) {
    for (final pending in _pendingFor(speaker)) {
      if (pending.generation == generation) {
        pending.expired = true;
        return;
      }
    }
  }

  void _resetActive() {
    _userBuffer = '';
    _assistantBuffer = '';
    _userTurnOpen = false;
    _userTurnClosed = false;
    _assistantInterrupted = false;
  }

  void reset() {
    _resetActive();
    _pendingUser.clear();
    _pendingAssistant.clear();
    _nextGeneration = 0;
  }
}

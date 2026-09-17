import 'turn_state.dart';

/// Translates Gemini Live's raw transcript signals into turn-machine events.
///
/// Mirrors `src/lib/turn-state/transcript-assembler.ts`. This is where the
/// cumulative-prefix bug lived on both platforms: the old code fired a graph
/// extraction at every sentence boundary carrying the whole turn-so-far, so
/// sentence one could commit, and then sentence one *plus* sentence two could
/// commit again on top of it — double-counting everything in the first.
///
/// Here, chunks only ever produce a *replaceable* interim transcript. Nothing
/// durable happens until a turn is explicitly completed.
///
/// Turn boundaries: Gemini's `turnComplete` describes the MODEL's turn. The
/// user turn ends earlier — server VAD detects end of speech and the model
/// starts answering — so the first assistant output after user speech is what
/// closes the user turn. A user turn the assistant never answered is closed by
/// `turnComplete` as a fallback.
class TranscriptAssembler {
  String _userBuffer = '';
  String _assistantBuffer = '';
  bool _userTurnOpen = false;
  bool _userTurnClosed = false;

  /// Current assistant display text — the basis for the heard watermark.
  String get assistantText => _assistantBuffer;

  /// The assistant answering is the signal that the user's turn is over.
  List<TurnEvent> _closeUserTurnIfNeeded() {
    if (!_userTurnOpen || _userTurnClosed) return const [];
    _userTurnClosed = true;
    return const [TurnCompleted(speaker: Speaker.user)];
  }

  List<TurnEvent> userChunk(String chunk) {
    if (chunk.isEmpty) return const [];
    _userBuffer += chunk;
    _userTurnOpen = true;
    return [InterimTranscript(speaker: Speaker.user, text: _userBuffer)];
  }

  /// Provider interim transcription: replaces the buffer, never appends.
  List<TurnEvent> userInterim(String text) {
    _userBuffer = text;
    _userTurnOpen = true;
    return [InterimTranscript(speaker: Speaker.user, text: _userBuffer)];
  }

  /// Final ("finished") user transcription chunk; closes the transcript.
  List<TurnEvent> userFinal(String chunk) {
    _userBuffer += chunk;
    final text = _userBuffer;
    _userBuffer = '';
    _userTurnOpen = true;
    if (text.trim().isEmpty) return const [];
    return [FinalTranscript(speaker: Speaker.user, text: text)];
  }

  List<TurnEvent> assistantChunk(String chunk) {
    if (chunk.isEmpty) return const [];
    final closing = _closeUserTurnIfNeeded();
    _assistantBuffer += chunk;
    return [
      ...closing,
      InterimTranscript(speaker: Speaker.assistant, text: _assistantBuffer),
    ];
  }

  List<TurnEvent> assistantFinal(String chunk) {
    final closing = _closeUserTurnIfNeeded();
    _assistantBuffer += chunk;
    final text = _assistantBuffer;
    _assistantBuffer = '';
    if (text.trim().isEmpty) return closing;
    return [...closing, FinalTranscript(speaker: Speaker.assistant, text: text)];
  }

  List<TurnEvent> turnComplete() {
    final events = <TurnEvent>[
      ..._closeUserTurnIfNeeded(),
      const TurnCompleted(speaker: Speaker.assistant),
    ];
    reset();
    return events;
  }

  List<TurnEvent> interrupted(int? heardChars) =>
      [AssistantInterrupted(heardChars: heardChars)];

  void reset() {
    _userBuffer = '';
    _assistantBuffer = '';
    _userTurnOpen = false;
    _userTurnClosed = false;
  }
}

/// Coordinates the one-time model opening that precedes user audio.
///
/// Gemini needs both an acknowledged setup and an initialized (or explicitly
/// unavailable) playback path before Lumen can safely begin speaking. The
/// first model turn then owns the floor until it completes.
class SessionOpeningCoordinator {
  bool _setupComplete = false;
  bool _playbackAttemptFinished = false;
  bool _openingSent = false;
  bool _openingComplete = false;

  bool get acceptsUserAudio => _openingComplete;

  /// Returns true exactly once, when setup and playback are both ready.
  bool markSetupComplete() {
    _setupComplete = true;
    return _claimOpeningIfReady();
  }

  /// Returns true exactly once, when setup and playback are both ready.
  bool markPlaybackAttemptFinished() {
    _playbackAttemptFinished = true;
    return _claimOpeningIfReady();
  }

  /// Opens the user-audio gate when the model's opening turn completes.
  ///
  /// Returns true only for that transition. Turn completions received before
  /// the opening was requested, or after it already completed, are ignored.
  bool markTurnComplete() {
    if (!_openingSent || _openingComplete) return false;
    _openingComplete = true;
    return true;
  }

  bool _claimOpeningIfReady() {
    if (!_setupComplete || !_playbackAttemptFinished || _openingSent) {
      return false;
    }
    _openingSent = true;
    return true;
  }
}

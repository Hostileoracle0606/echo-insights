/// Lumen's greeting owns the floor at the start of every session.
///
/// The greeting is a bundled clip played locally (see StandardOpening), so
/// there is no model turn to request. The mic stays gated until the greeting
/// has been *heard* — its audio drained — or until it's clear it can't play.
class SessionOpeningCoordinator {
  bool _greetingClaimed = false;
  bool _heard = false;

  bool get acceptsUserAudio => _heard;

  /// Lumen has the floor: the greeting is pending or playing.
  bool get inProgress => !_heard;

  /// True exactly once, for whoever gets to start the greeting — and never
  /// after the floor has already passed to the user.
  bool claimGreeting() {
    if (_greetingClaimed || _heard) return false;
    _greetingClaimed = true;
    return true;
  }

  /// The greeting finished playing (or cannot play). Returns true only for
  /// the transition that opens the mic.
  bool markOpeningHeard() {
    if (_heard) return false;
    _heard = true;
    return true;
  }
}

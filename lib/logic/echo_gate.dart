import 'dart:typed_data';

/// Keeps Lumen's own voice out of the mic where nothing cancels it.
///
/// On a device, Apple's voice processing removes Lumen's playback from the
/// mic, so the user can talk over Lumen. Where it doesn't run (always on the
/// iOS Simulator: the Mac's speakers feed the Mac's mic), Gemini hears Lumen
/// as the user, interrupts itself and answers its own words. Without echo
/// cancellation the mic therefore goes out as silence while Lumen is audible
/// and for [tail] after, so the room's echo has died down. Silence rather
/// than nothing keeps the stream's timing intact for Gemini's voice
/// detection. The cost is that Lumen can't be interrupted by voice there.
class EchoGate {
  EchoGate({
    required this.echoCancelled,
    this.tail = const Duration(milliseconds: 300),
  });

  final bool echoCancelled;
  final Duration tail;

  bool _audible = false;
  DateTime? _quietSince;

  /// Lumen's voice started or stopped playing (the player's clock).
  void lumenAudible(bool audible, {required DateTime at}) {
    if (audible == _audible) return;
    _audible = audible;
    _quietSince = audible ? null : at;
  }

  /// The frame to send for [pcm16], captured [at].
  Uint8List admit(Uint8List pcm16, {required DateTime at}) {
    if (echoCancelled || !_closed(at)) return pcm16;
    return Uint8List(pcm16.length);
  }

  bool _closed(DateTime at) {
    if (_audible) return true;
    final quietSince = _quietSince;
    return quietSince != null && at.difference(quietSince) <= tail;
  }
}

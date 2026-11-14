/// Where the phone is sending sound right now, as the native voice engine
/// reports it (AVAudioSession.currentRoute).
enum AudioRoute {
  /// The phone's own speaker or earpiece.
  builtIn,

  /// Wired or USB headphones.
  headphones,

  /// Any Bluetooth audio output (A2DP, HFP, LE).
  bluetooth,

  /// AirPlay, car audio, HDMI, anything else.
  other,

  /// Not reported (yet).
  unknown;

  static AudioRoute parse(Object? value) => switch (value) {
        'builtIn' => AudioRoute.builtIn,
        'headphones' => AudioRoute.headphones,
        'bluetooth' => AudioRoute.bluetooth,
        'other' => AudioRoute.other,
        _ => AudioRoute.unknown,
      };
}

/// Quiet mode: Lumen speaks aloud only into headphones or Bluetooth audio.
/// With it off, everything plays. With it on, anything else, including a
/// route we can't read, stays silent: the words still appear as text.
bool quietModeAllowsPlayback({
  required bool quietMode,
  required AudioRoute route,
}) {
  if (!quietMode) return true;
  return route == AudioRoute.headphones || route == AudioRoute.bluetooth;
}

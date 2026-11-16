import 'dart:async';

import '../logic/voice_log.dart';
import 'pcm_player.dart';

/// The signed-in user's one speaker: a single [PcmPlayer], initialised at
/// sign-in and reused by every session, disposed at sign-out.
///
/// The player's `init()` can stall for minutes on the simulator
/// (just_audio / AVFoundation -11800), so nothing ever waits on it for
/// longer than it chooses: [player] is null until the player is ready, and
/// [whenReady] gives up after its own timeout without disturbing the init.
class AudioOutput {
  AudioOutput({
    PcmPlayer Function()? createPlayer,
    Future<void> Function()? prepare,
    this.initTimeout = const Duration(seconds: 5),
  })  : _createPlayer = createPlayer ?? PcmPlayer.new,
        _prepare = prepare;

  final PcmPlayer Function() _createPlayer;
  final Future<void> Function()? _prepare;

  /// A player not ready by then is abandoned (disposed in the background);
  /// the next [start] tries a fresh one.
  final Duration initTimeout;

  PcmPlayer? _ready;
  Future<PcmPlayer?>? _starting;
  int _generation = 0;

  /// The ready player, or null while it starts, after it failed, or when
  /// signed out.
  PcmPlayer? get player => _ready;

  /// Starts the player once. Concurrent and repeated calls share one start;
  /// a failed start can be retried by calling again.
  Future<PcmPlayer?> start() {
    final ready = _ready;
    if (ready != null && !ready.isDisposed) return Future.value(ready);
    return _starting ??= _start(_generation);
  }

  /// The player, waiting at most [timeout] for a start in progress (starting
  /// one if needed). Null on timeout; the start carries on regardless.
  Future<PcmPlayer?> whenReady({
    Duration timeout = const Duration(seconds: 5),
  }) {
    return start().timeout(timeout, onTimeout: () => null);
  }

  Future<PcmPlayer?> _start(int generation) async {
    final player = _createPlayer();
    try {
      await _prepare?.call();
      await player.init().timeout(initTimeout);
      if (generation != _generation || player.isDisposed) {
        unawaited(player.dispose().catchError((_) {}));
        return null;
      }
      _ready = player;
      vlog('playback', 'app-level player ready');
      return player;
    } catch (error) {
      vlog('playback', 'player unavailable, sessions continue without it: '
          '$error');
      unawaited(player.dispose().catchError((_) {}));
      return null;
    } finally {
      if (generation == _generation) _starting = null;
    }
  }

  /// Signed out: releases the player. A start in progress is abandoned.
  Future<void> stop() async {
    _generation += 1;
    _starting = null;
    final player = _ready;
    _ready = null;
    if (player == null) return;
    try {
      await player.dispose().timeout(initTimeout);
    } catch (error) {
      vlog('playback', 'player shutdown incomplete: $error');
    }
  }
}

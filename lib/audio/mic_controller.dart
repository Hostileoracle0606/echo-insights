import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';

import '../logic/voice_log.dart';
import 'pcm_capture.dart';

/// What the microphone should do in response to an audio-session event.
enum MicAction { none, suspend, resume, restart }

/// A phone call, Siri or an alarm begins → suspend. On the end event, iOS sets
/// AVAudioSessionInterruptionOptionShouldResume only when it is appropriate
/// to resume; audio_session reports that as [AudioInterruptionType.pause].
/// Without it, stay suspended until the app is foregrounded again.
MicAction micActionForInterruption(AudioInterruptionEvent event) {
  if (event.begin) return MicAction.suspend;
  return event.type == AudioInterruptionType.pause
      ? MicAction.resume
      : MicAction.none;
}

/// A headset or Bluetooth input appearing or disappearing moves the input
/// route. Restarting capture rebinds the recorder to the new route instead of
/// leaving it tapping a device that is gone.
MicAction micActionForDevicesChanged(AudioDevicesChangedEvent event) {
  final changed = {...event.devicesAdded, ...event.devicesRemoved};
  return changed.any((device) => device.isInput)
      ? MicAction.restart
      : MicAction.none;
}

/// Owns a live session's [PcmCapture] and serializes every stop/start, so
/// interruption, route-change and app-lifecycle events cannot interleave and
/// leave the recorder half-started.
class MicController {
  MicController(
    this._capture,
    this._onChunk, {
    Future<void> Function()? reactivate,
  }) : _reactivate = reactivate;

  final PcmCapture _capture;
  final void Function(Uint8List pcm16) _onChunk;

  /// Re-activates the audio session before capture resumes after an
  /// interruption (the system deactivated it).
  final Future<void> Function()? _reactivate;

  bool _running = false;
  bool _suspended = false;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();

  /// True after an interruption until capture is successfully resumed.
  bool get suspended => _suspended;

  /// First start. Errors propagate to the caller (startSession).
  Future<void> start() => _serialized(() async {
        if (_closed || _running) return;
        await _capture.start(_onChunk);
        _running = true;
        _suspended = false;
      });

  Future<void> apply(MicAction action) {
    switch (action) {
      case MicAction.none:
        return Future<void>.value();
      case MicAction.suspend:
        return suspend();
      case MicAction.resume:
        return resume();
      case MicAction.restart:
        return restart();
    }
  }

  Future<void> suspend() => _serialized(() async {
        if (_closed || !_running) return;
        _running = false;
        _suspended = true;
        await _guard('suspend', _capture.stop);
      });

  /// Resumes after [suspend]. On failure (for example the call is still
  /// holding the audio session) it stays suspended, so a later resume, such
  /// as the app returning to the foreground, can retry.
  Future<void> resume() => _serialized(() async {
        if (_closed || !_suspended) return;
        final ok = await _guard('resume', () async {
          await _reactivate?.call();
          await _capture.start(_onChunk);
        });
        if (ok && !_closed) {
          _running = true;
          _suspended = false;
        }
      });

  Future<void> restart() => _serialized(() async {
        if (_closed || !_running) return;
        await _guard('restart stop', _capture.stop);
        final ok = await _guard('restart', () => _capture.start(_onChunk));
        if (!ok) {
          // Leave it resumable rather than silently dead.
          _running = false;
          _suspended = true;
        }
      });

  /// Final stop. Anything queued behind it becomes a no-op.
  Future<void> stop() {
    _closed = true;
    return _serialized(() async {
      final wasRunning = _running;
      _running = false;
      _suspended = false;
      if (wasRunning) await _capture.stop();
    });
  }

  Future<bool> _guard(String what, Future<void> Function() op) async {
    try {
      await op();
      return true;
    } catch (error) {
      vlog('capture', '$what failed: $error');
      return false;
    }
  }

  Future<void> _serialized(Future<void> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

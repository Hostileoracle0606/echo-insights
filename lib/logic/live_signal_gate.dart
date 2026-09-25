import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// One thing Gemini Live told us, captured so it can be held back and
/// replayed. Tool calls are not signals: they need answers immediately and
/// are served even while the session is only warm.
sealed class LiveSignal {
  const LiveSignal();
}

class AgentAudio extends LiveSignal {
  const AgentAudio(this.pcm, this.sampleRate);
  final Uint8List pcm;
  final int sampleRate;

  /// Play time of this PCM16 mono chunk.
  Duration get duration => sampleRate <= 0
      ? Duration.zero
      : Duration(microseconds: (pcm.length / 2 / sampleRate * 1e6).round());
}

class AgentTranscript extends LiveSignal {
  const AgentTranscript(this.text, this.isFinal);
  final String text;
  final bool isFinal;
}

class UserTranscript extends LiveSignal {
  const UserTranscript(this.text, this.isFinal);
  final String text;
  final bool isFinal;
}

class TurnCompleteSignal extends LiveSignal {
  const TurnCompleteSignal();
}

class InterruptedSignal extends LiveSignal {
  const InterruptedSignal();
}

/// Holds a warm session's signals until the user taps, then replays them.
///
/// Before [activate], every signal is buffered: Lumen's pre-sent opening
/// must not reach the transcript, the turn machine, extraction or the
/// speaker unless the user actually starts the session.
///
/// On [activate], buffered audio goes to the sink at once (it simply queues
/// for playback) while every other signal is *paced*: delivered when the
/// audio that preceded it would have finished playing. Replaying the buffer
/// in one burst would put Lumen's whole opening on screen — and complete its
/// turn, opening the mic — while its voice was still on the first sentence.
/// Signals that arrive while the replay is still pacing queue behind it, so
/// order is preserved; once it drains, signals pass straight through.
class LiveSignalGate {
  LiveSignalGate({Duration Function()? now}) : _now = now ?? _monotonic();

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final Duration Function() _now;
  final List<LiveSignal> _buffer = [];
  final Queue<(Duration, LiveSignal)> _paced = Queue();
  void Function(LiveSignal)? _sink;
  Duration _activatedAt = Duration.zero;

  // Audio handed to the sink since activation, as play time.
  Duration _audioFed = Duration.zero;
  Timer? _timer;
  bool _disposed = false;

  bool get isActivated => _sink != null;

  /// Replayed signals are still waiting for their audio to catch up.
  bool get isPacing => _paced.isNotEmpty;

  /// Signals held back so far (before activation).
  int get buffered => _buffer.length;

  void receive(LiveSignal signal) {
    if (_disposed) return;
    final sink = _sink;
    if (sink == null) {
      _buffer.add(signal);
      return;
    }
    if (signal is AgentAudio) {
      _audioFed += signal.duration;
      sink(signal);
      return;
    }
    if (_paced.isEmpty) {
      sink(signal);
      return;
    }
    _paced.add((_audioFed, signal));
    _pump();
  }

  /// Starts delivering to [sink]: buffered audio now, the rest paced.
  void activate(void Function(LiveSignal) sink) {
    if (_disposed || _sink != null) return;
    _sink = sink;
    _activatedAt = _now();
    for (final signal in _buffer) {
      if (signal is AgentAudio) {
        _audioFed += signal.duration;
        sink(signal);
      } else {
        _paced.add((_audioFed, signal));
      }
    }
    _buffer.clear();
    _pump();
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    final sink = _sink;
    if (_disposed || sink == null) return;
    while (_paced.isNotEmpty) {
      final (due, signal) = _paced.first;
      final wait = due - (_now() - _activatedAt);
      if (wait > Duration.zero) {
        _timer = Timer(wait, _pump);
        return;
      }
      _paced.removeFirst();
      sink(signal);
      if (_disposed) return;
    }
  }

  /// Discards everything; later signals are ignored.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
    _paced.clear();
  }
}

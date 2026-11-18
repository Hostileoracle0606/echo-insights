import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Prefix of every timing line, so a collector can pick them out of a log.
const timingLinePrefix = '[lumen-timing]';

/// The only field keys a mark may carry. Values are numbers or booleans:
/// never text, names, ids or tokens. `scope` is a [RetrievalScope] index.
const allowedFieldKeys = {
  'count',
  'bytes',
  'overlap',
  'scope',
  'size',
  'ok',
  'retry',
};

/// On only in builds made with `--dart-define=LUMEN_TIMING=1`.
const _timingDefine = String.fromEnvironment('LUMEN_TIMING');

/// Whether a LUMEN_TIMING define value turns timing on ("1" or "true").
bool timingEnabledFor(String value) => value == '1' || value == 'true';

/// An entity count as its order of magnitude (0, 1, 10, 100, 1000+), so a
/// mark says how large a history is without saying exactly.
int entityCountBucket(int count) {
  if (count <= 0) return 0;
  var bucket = 1;
  while (bucket < 1000 && count >= bucket * 10) {
    bucket *= 10;
  }
  return bucket;
}

String get _buildMode =>
    kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release');

/// Content-free timing marks for the responsiveness eval: one JSON line per
/// mark, offsets from one monotonic [Stopwatch] started in `main()`.
///
/// Unlike `vlog`, it works in profile builds, and it is silent unless the
/// build defines `LUMEN_TIMING=1`, so shipped builds behave as before.
class TimingMarks {
  TimingMarks({
    bool? enabled,
    bool strict = kDebugMode,
    String? mode,
    Stopwatch? clock,
    void Function(String line)? sink,
  })  : enabled = enabled ?? timingEnabledFor(_timingDefine),
        _strict = strict,
        _mode = mode ?? _buildMode,
        _clock = clock ?? Stopwatch(),
        _sink = sink ?? _print;

  static final instance = TimingMarks();

  final bool enabled;
  final bool _strict;
  final String _mode;
  final Stopwatch _clock;
  final void Function(String line) _sink;
  final Map<String, int> _open = {};
  final Set<String> _once = {};

  /// Whether a live session is active now. Background work that ends while
  /// it is records `overlap`.
  bool turnActive = false;

  // `print`, not `debugPrint`: it must reach the console in profile builds.
  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Starts the clock. Call first thing in `main()`; later calls are no-ops.
  void start() {
    if (!_clock.isRunning) _clock.start();
  }

  /// A point in time, such as `first_frame`.
  void mark(String stage, {Map<String, Object> fields = const {}}) {
    if (!enabled) return;
    _emit(stage, 'mark', fields: fields);
  }

  /// As [mark], for a stage that happens once per app run.
  void markOnce(String stage, {Map<String, Object> fields = const {}}) {
    if (!enabled || !_once.add(stage)) return;
    _emit(stage, 'mark', fields: fields);
  }

  /// The start of a stage that [end] closes.
  void begin(String stage) {
    if (!enabled) return;
    _emit(stage, 'begin');
    _open[stage] = _clock.elapsedMilliseconds;
  }

  /// The end of a stage. Without an open [begin] it is `incomplete`.
  void end(String stage, {Map<String, Object> fields = const {}}) {
    if (!enabled) return;
    final began = _open.remove(stage);
    _emit(stage, 'end', began: began, incomplete: began == null,
        fields: fields);
  }

  /// The clock now, for a later [span].
  int get now => _clock.elapsedMilliseconds;

  /// A whole stage in one line, timed from [since] (read from [now]). For
  /// stages that can run concurrently with themselves, where begin/end
  /// pairing by name would cross.
  void span(String stage,
      {required int since, Map<String, Object> fields = const {}}) {
    if (!enabled) return;
    _emit(stage, 'span', began: since, fields: fields);
  }

  /// Whether [stage] has begun and not yet ended.
  bool isOpen(String stage) => _open.containsKey(stage);

  void _emit(String stage, String phase,
      {int? began, bool incomplete = false, Map<String, Object> fields = const {}}) {
    final safe = _checked(fields);
    final now = _clock.elapsedMilliseconds;
    final line = <String, Object>{
      'v': 1,
      'stage': stage,
      'phase': phase,
      't_ms': now,
      if (began != null) 'dur_ms': now - began,
      if (incomplete) 'incomplete': true,
      'mode': _mode,
      ...safe,
    };
    _sink('$timingLinePrefix ${jsonEncode(line)}');
  }

  Map<String, Object> _checked(Map<String, Object> fields) {
    final safe = <String, Object>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      final okKey = allowedFieldKeys.contains(entry.key);
      final okValue = value is num || value is bool;
      if (okKey && okValue) {
        safe[entry.key] = value;
      } else if (_strict) {
        throw ArgumentError.value(
            okKey ? value.runtimeType : entry.key,
            okKey ? 'timing field value' : 'timing field key',
            'timing marks carry allow-listed keys with number or boolean '
                'values only');
      }
    }
    return safe;
  }
}

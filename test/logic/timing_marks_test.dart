// Content-free timing marks: stage names, ms offsets, counts and booleans
// only, and nothing at all unless the build defines LUMEN_TIMING=1.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/timing_marks.dart';

/// A clock the test moves by hand.
class _ManualClock extends Stopwatch {
  int ms = 0;
  @override
  int get elapsedMilliseconds => ms;
}

Map<String, dynamic> _json(String line) {
  expect(line, startsWith('$timingLinePrefix '));
  return jsonDecode(line.substring(timingLinePrefix.length + 1))
      as Map<String, dynamic>;
}

void main() {
  late List<String> lines;
  late _ManualClock clock;

  TimingMarks marks({bool enabled = true, bool strict = true}) => TimingMarks(
        enabled: enabled,
        strict: strict,
        mode: 'profile',
        clock: clock,
        sink: lines.add,
      );

  setUp(() {
    lines = [];
    clock = _ManualClock();
  });

  test('the shared recorder is off unless LUMEN_TIMING is defined', () {
    expect(TimingMarks.instance.enabled, isFalse);
  });

  test('disabled: nothing is emitted', () {
    final m = marks(enabled: false)..start();
    m.mark('first_frame');
    m.begin('notebook_open');
    m.end('notebook_open');
    expect(lines, isEmpty);
  });

  test('a mark is one prefixed JSON line with t_ms from the clock', () {
    final m = marks()..start();
    clock.ms = 123;
    m.mark('first_frame');
    expect(lines, hasLength(1));
    expect(_json(lines.single), {
      'v': 1,
      'stage': 'first_frame',
      'phase': 'mark',
      't_ms': 123,
      'mode': 'profile',
    });
  });

  test('begin then end emits both, the end carrying dur_ms and fields', () {
    final m = marks()..start();
    clock.ms = 100;
    m.begin('notebook_open');
    clock.ms = 145;
    m.end('notebook_open', fields: {'size': 50});
    expect(lines.map(_json).toList(), [
      {'v': 1, 'stage': 'notebook_open', 'phase': 'begin', 't_ms': 100,
        'mode': 'profile'},
      {'v': 1, 'stage': 'notebook_open', 'phase': 'end', 't_ms': 145,
        'dur_ms': 45, 'mode': 'profile', 'size': 50},
    ]);
  });

  test('end without begin is marked incomplete, with no duration', () {
    final m = marks()..start();
    clock.ms = 9;
    m.end('commit');
    final line = _json(lines.single);
    expect(line['incomplete'], isTrue);
    expect(line.containsKey('dur_ms'), isFalse);
  });

  test('a stage that ends twice is incomplete the second time', () {
    final m = marks()..start();
    m.begin('commit');
    m.end('commit');
    m.end('commit');
    expect(_json(lines.last)['incomplete'], isTrue);
  });

  test('an unknown field key throws in strict (debug) mode', () {
    final m = marks()..start();
    expect(() => m.mark('commit', fields: {'text': 3}), throwsArgumentError);
    expect(lines, isEmpty);
  });

  test('an unknown field key is dropped when not strict (profile)', () {
    final m = marks(strict: false)..start();
    m.mark('commit', fields: {'text': 3, 'retry': true});
    final line = _json(lines.single);
    expect(line.containsKey('text'), isFalse);
    expect(line['retry'], isTrue);
  });

  test('a string value is rejected even under an allowed key', () {
    expect(() => marks()..start()..mark('retrieval', fields: {'scope': 'user'}),
        throwsArgumentError);
    final m = marks(strict: false)..start();
    m.mark('retrieval', fields: {'scope': 'Maya Chen', 'count': 3});
    final line = _json(lines.single);
    expect(line.containsKey('scope'), isFalse);
    expect(line['count'], 3);
  });

  test('only allow-listed keys, numbers and booleans ever reach the line', () {
    expect(allowedFieldKeys,
        {'count', 'bytes', 'overlap', 'scope', 'size', 'ok', 'retry'});
    final m = marks(strict: false)..start();
    m.mark('x', fields: {
      for (final k in allowedFieldKeys) k: 1,
      'id': 7,
      'name': 'Priya',
    });
    final line = _json(lines.single);
    expect(line.keys.toSet().difference({'v', 'stage', 'phase', 't_ms', 'mode'}),
        allowedFieldKeys);
  });
}

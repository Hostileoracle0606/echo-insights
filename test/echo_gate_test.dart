import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/echo_gate.dart';

Uint8List _speech() => Uint8List.fromList([1, 2, 3, 4]);
bool _silent(Uint8List pcm) => pcm.every((b) => b == 0);

void main() {
  final t0 = DateTime.utc(2026, 10, 27, 12);

  test('with echo cancellation, the mic always goes out as it is', () {
    final gate = EchoGate(echoCancelled: true);
    gate.lumenAudible(true, at: t0);
    final out = gate.admit(_speech(), at: t0);
    expect(out, _speech());
  });

  test('without it, the mic goes out as silence while Lumen plays', () {
    final gate = EchoGate(echoCancelled: false);
    gate.lumenAudible(true, at: t0);
    final out = gate.admit(_speech(), at: t0.add(const Duration(seconds: 2)));
    expect(out, hasLength(4), reason: 'same length keeps the stream timed');
    expect(_silent(out), isTrue);
  });

  test('and for a short tail after Lumen stops, then opens again', () {
    final gate = EchoGate(echoCancelled: false, tail: const Duration(milliseconds: 300));
    gate.lumenAudible(true, at: t0);
    gate.lumenAudible(false, at: t0.add(const Duration(seconds: 1)));

    final inTail = gate.admit(_speech(), at: t0.add(const Duration(milliseconds: 1200)));
    expect(_silent(inTail), isTrue, reason: 'room echo still decaying');

    final after = gate.admit(_speech(), at: t0.add(const Duration(milliseconds: 1301)));
    expect(after, _speech());
  });

  test('without it, the mic is open while Lumen is quiet', () {
    final gate = EchoGate(echoCancelled: false);
    expect(gate.admit(_speech(), at: t0), _speech());
  });

  test('never alters the frame it was given', () {
    final gate = EchoGate(echoCancelled: false);
    final frame = _speech();
    gate.lumenAudible(true, at: t0);
    gate.admit(frame, at: t0);
    expect(frame, _speech());
  });
}

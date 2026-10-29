import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/reply_timer.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 27, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('a typed turn times the tool call and the first audio', () {
    final timer = ReplyTimer();
    timer.userTurn(at(0), typed: true);
    expect(timer.toolCall(at(450)), 'typed turn → tool call +450ms');
    expect(timer.replyAudio(at(1200)),
        'typed turn → reply audio +1200ms (tool call at +450ms)');
  });

  test('a spoken turn is timed from its last transcript chunk', () {
    final timer = ReplyTimer();
    timer.userTurn(at(0));
    timer.userTurn(at(300));
    expect(timer.replyAudio(at(1000)), 'spoken turn → reply audio +700ms');
  });

  test('only the first tool call and first audio chunk are reported', () {
    final timer = ReplyTimer();
    timer.userTurn(at(0), typed: true);
    expect(timer.toolCall(at(400)), isNotNull);
    expect(timer.toolCall(at(500)), isNull);
    expect(timer.replyAudio(at(900)), isNotNull);
    expect(timer.replyAudio(at(950)), isNull);
  });

  test('a transcript chunk arriving while Lumen replies is not a new turn',
      () {
    final timer = ReplyTimer();
    timer.userTurn(at(0));
    timer.replyAudio(at(800));
    timer.userTurn(at(900));
    expect(timer.replyAudio(at(1000)), isNull);
    timer.replyEnded();
    timer.userTurn(at(2000));
    expect(timer.replyAudio(at(2600)), 'spoken turn → reply audio +600ms');
  });

  test('audio with no user turn before it (the greeting) is not timed', () {
    final timer = ReplyTimer();
    expect(timer.toolCall(at(100)), isNull);
    expect(timer.replyAudio(at(200)), isNull);
  });

  group('StallWatch', () {
    test('reports a tick that came much later than scheduled', () {
      final watch = StallWatch(interval: const Duration(milliseconds: 250));
      expect(watch.tick(const Duration(milliseconds: 260)), isNull);
      expect(watch.tick(const Duration(milliseconds: 1900)),
          'app unresponsive for ~1650ms');
    });
  });
}

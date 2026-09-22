import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/live_session_guard.dart';

void main() {
  test('invalidating a session rejects every callback holding its old lease',
      () {
    final guard = LiveSessionGuard();
    final sessionA = guard.begin().bind(
          notebookId: 'notebook-a',
          sessionId: 'session-a',
        );

    expect(guard.isCurrent(sessionA), isTrue);

    guard.invalidate();

    expect(guard.isCurrent(sessionA), isFalse);
  });

  test('starting a replacement session invalidates the previous generation',
      () {
    final guard = LiveSessionGuard();
    final sessionA = guard.begin().bind(
          notebookId: 'notebook-a',
          sessionId: 'session-a',
        );
    final sessionB = guard.begin().bind(
          notebookId: 'notebook-b',
          sessionId: 'session-b',
        );

    expect(guard.isCurrent(sessionA), isFalse);
    expect(guard.isCurrent(sessionB), isTrue);
    expect(sessionB.notebookId, 'notebook-b');
    expect(sessionB.sessionId, 'session-b');
  });
}

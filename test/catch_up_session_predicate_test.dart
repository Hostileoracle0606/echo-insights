// LM-103: catch-up stays off a notebook only while a session is actually on
// it. A leave that failed (offline at session end: status error, notebook
// still set) is not live, so a plain resume finishes the notebook.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/journal_provider.dart';

void main() {
  test('connecting, live, paused and ending are live', () {
    for (final status in [
      SessionStatus.connecting,
      SessionStatus.live,
      SessionStatus.paused,
      SessionStatus.ending,
    ]) {
      expect(sessionIsLive(status), isTrue, reason: status.name);
    }
  });

  test('a failed leave is not live, even with a turn left pending', () {
    expect(sessionIsLive(SessionStatus.error), isFalse);
    expect(sessionIsLive(SessionStatus.error, extracting: true), isFalse);
  });

  test('idle is live only while a turn is still extracting or committing', () {
    expect(sessionIsLive(SessionStatus.idle), isFalse);
    expect(sessionIsLive(SessionStatus.idle, extracting: true), isTrue);
  });

  test('after a failed leave the notifier no longer owns the open turns', () {
    expect(catchUpOwnsNotebook(SessionStatus.error), isFalse);
    for (final status in SessionStatus.values) {
      if (status == SessionStatus.error) continue;
      expect(catchUpOwnsNotebook(status), isTrue, reason: status.name);
    }
  });
}

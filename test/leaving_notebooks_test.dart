import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/leaving_notebooks_provider.dart';

void main() {
  test('a leave in progress is pending until it finishes', () async {
    final leaving = LeavingNotebooks();
    final done = Completer<void>();

    leaving.track('nb-1', done.future);
    expect(leaving.pending('nb-1'), isNotNull);
    expect(leaving.pending('nb-2'), isNull);

    done.complete();
    await Future<void>.delayed(Duration.zero);
    expect(leaving.pending('nb-1'), isNull);
  });

  test('a failed leave stays until the notebook is left again', () async {
    final leaving = LeavingNotebooks();
    final failure = LeaveIncomplete(retry: () async {});

    leaving.track('nb-1', Future<void>.error(failure));
    await Future<void>.delayed(Duration.zero);
    await expectLater(leaving.pending('nb-1'), throwsA(same(failure)));

    final again = Completer<void>();
    leaving.track('nb-1', again.future);
    expect(leaving.pending('nb-1'), same(again.future));
  });

  test('an earlier leave finishing does not clear a later one', () async {
    final leaving = LeavingNotebooks();
    final first = Completer<void>();
    final second = Completer<void>();

    leaving
      ..track('nb-1', first.future)
      ..track('nb-1', second.future);
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(leaving.pending('nb-1'), same(second.future));
  });
}

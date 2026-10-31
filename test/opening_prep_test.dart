import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/services/session_brief_service.dart';

class _FakeService implements SessionBriefService {
  final loads = <Completer<SessionOpeningState>>[];

  @override
  Future<SessionOpeningState> load() {
    final c = Completer<SessionOpeningState>();
    loads.add(c);
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionOpeningState _state(
        {DateTime? playedAt, String line = 'Hi', DateTime? created}) =>
    SessionOpeningState(
      returning: true,
      brief: SessionBrief(
        focus: const [],
        openingThread: 't',
        openingLine: line,
        createdAt: created ?? DateTime.utc(2026, 10, 28, 23, 57, 1, 123, 456),
        playedAt: playedAt,
        pcm: Uint8List.fromList([1, 2]),
        sampleRate: 24000,
      ),
    );

void main() {
  late _FakeService service;
  late OpeningPrep prep;

  setUp(() {
    service = _FakeService();
    prep = OpeningPrep(service);
  });

  test('refresh never throws and keeps the previous state on failure',
      () async {
    final first = prep.refresh();
    service.loads[0].complete(_state());
    await first;
    final before = prep.current;
    expect(before, isNotNull);

    final second = prep.refresh();
    service.loads[1].completeError(StateError('offline'));
    await second;
    expect(prep.current, same(before));
  });

  test('a superseded, slower refresh does not overwrite a newer one', () async {
    final older = prep.refresh();
    final newer = prep.refresh();
    service.loads[1].complete(_state(line: 'newer'));
    await newer;
    service.loads[0].complete(_state(line: 'older'));
    await older;
    expect(prep.current!.brief!.openingLine, 'newer');
  });

  test('an unplayed reload after markPlayedLocally stays played', () async {
    final first = prep.refresh();
    service.loads[0].complete(_state());
    await first;
    final inFlight = prep.refresh();
    prep.markPlayedLocally();
    service.loads[1].complete(_state());
    await inFlight;
    expect(prep.current!.brief!.playedAt, isNotNull);

    final later = prep.refresh();
    service.loads[2].complete(_state());
    await later;
    expect(prep.current!.brief!.playedAt, isNotNull);
  });

  test('a newer brief after markPlayedLocally is not marked played', () async {
    final first = prep.refresh();
    service.loads[0].complete(_state());
    await first;
    prep.markPlayedLocally();
    final next = prep.refresh();
    service.loads[1].complete(_state(created: DateTime.utc(2026, 10, 29, 8)));
    await next;
    expect(prep.current!.brief!.playedAt, isNull);
  });

  test('clear drops state; a load started before it does not repopulate',
      () async {
    final first = prep.refresh();
    service.loads[0].complete(_state());
    await first;
    prep.markNewAccount();

    final inFlight = prep.refresh();
    prep.clear();
    expect(prep.current, isNull);
    expect(prep.knownNewAccount, isFalse);
    service.loads[1].complete(_state());
    await inFlight;
    expect(prep.current, isNull);
  });

  test('markNewAccount then markIntroPlayed', () {
    expect(prep.knownNewAccount, isFalse);
    prep.markNewAccount();
    expect(prep.knownNewAccount, isTrue);
    prep.markIntroPlayed();
    expect(prep.knownNewAccount, isFalse);
  });

  test('markPlayedLocally with no brief is a no-op', () async {
    prep.markPlayedLocally();
    expect(prep.current, isNull);
    final r = prep.refresh();
    service.loads[0]
        .complete(const SessionOpeningState(returning: true, brief: null));
    await r;
    prep.markPlayedLocally();
    expect(prep.current!.brief, isNull);
  });

  test('markReturning with no state yet makes the account returning', () {
    prep.markReturning();
    expect(prep.current!.returning, isTrue);
    expect(prep.current!.brief, isNull);
  });

  test('markReturning keeps the current brief, played or not', () async {
    final first = prep.refresh();
    service.loads[0].complete(SessionOpeningState(
      returning: false,
      brief: _state().brief,
    ));
    await first;
    prep.markPlayedLocally();
    prep.markReturning();
    expect(prep.current!.returning, isTrue);
    expect(prep.current!.brief!.openingLine, 'Hi');
    expect(prep.current!.brief!.playedAt, isNotNull);
  });

  test('a load issued before markReturning cannot make the account new again',
      () async {
    final inFlight = prep.refresh();
    prep.markReturning();
    service.loads[0]
        .complete(const SessionOpeningState(returning: false, brief: null));
    await inFlight;
    expect(prep.current!.returning, isTrue);
  });

  test('a later refresh still replaces the brief after markReturning',
      () async {
    prep.markReturning();
    final r = prep.refresh();
    service.loads[0].complete(_state(line: 'fresh'));
    await r;
    expect(prep.current!.returning, isTrue);
    expect(prep.current!.brief!.openingLine, 'fresh');
  });

  test('clear forgets markReturning', () async {
    prep.markReturning();
    prep.clear();
    expect(prep.current, isNull);
    final r = prep.refresh();
    service.loads[0]
        .complete(const SessionOpeningState(returning: false, brief: null));
    await r;
    expect(prep.current!.returning, isFalse);
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/opening_choice.dart';
import 'package:lumen/models/session_brief.dart';

void main() {
  final now = DateTime(2026, 10, 29, 9);

  SessionBrief brief({
    DateTime? createdAt,
    DateTime? playedAt,
    Uint8List? pcm,
  }) =>
      SessionBrief(
        focus: const ['a'],
        openingThread: 't',
        openingLine: 'Hi',
        createdAt: createdAt ?? now.subtract(const Duration(days: 1)),
        playedAt: playedAt,
        pcm: pcm ?? Uint8List.fromList([1, 2, 3, 4]),
        sampleRate: 24000,
      );

  SessionOpeningState state(SessionBrief? b, {bool returning = true}) =>
      SessionOpeningState(returning: returning, brief: b);

  OpeningChoice choose(SessionOpeningState? s, {bool isNew = false}) =>
      chooseOpening(state: s, knownNewAccount: isNew, now: now);

  test('a known new account gets the intro even with a brief', () {
    expect(
      choose(state(brief(), returning: false), isNew: true),
      OpeningChoice.intro,
    );
  });

  test('a known new account with no state yet gets the intro', () {
    expect(choose(null, isNew: true), OpeningChoice.intro);
  });

  test(
      'a known returning account never gets the intro, even if signed up '
      'in this run', () {
    expect(choose(state(brief()), isNew: true), OpeningChoice.brief);
    expect(choose(state(null), isNew: true), OpeningChoice.fallback);
    expect(
      choose(state(brief(playedAt: now)), isNew: true),
      OpeningChoice.fallback,
    );
  });

  test('no state falls back', () {
    expect(choose(null), OpeningChoice.fallback);
  });

  test('a non-returning account gets the intro', () {
    expect(choose(state(null, returning: false)), OpeningChoice.intro);
  });

  test('a usable brief is played', () {
    expect(choose(state(brief())), OpeningChoice.brief);
  });

  test('a played brief falls back', () {
    expect(choose(state(brief(playedAt: now))), OpeningChoice.fallback);
  });

  test('21 days old falls back; 20 days 23 h is still usable', () {
    expect(
      choose(state(brief(createdAt: now.subtract(const Duration(days: 21))))),
      OpeningChoice.fallback,
    );
    expect(
      choose(state(brief(
        createdAt: now.subtract(const Duration(days: 20, hours: 23)),
      ))),
      OpeningChoice.brief,
    );
  });

  test('staleAt is true from 21 days on', () {
    expect(
        brief(createdAt: now.subtract(const Duration(days: 21))).staleAt(now),
        isTrue);
    expect(
      brief(createdAt: now.subtract(const Duration(days: 20, hours: 23)))
          .staleAt(now),
      isFalse,
    );
  });

  test('empty audio falls back', () {
    expect(choose(state(brief(pcm: Uint8List(0)))), OpeningChoice.fallback);
  });

  test('a returning account with no brief falls back', () {
    expect(choose(state(null)), OpeningChoice.fallback);
  });
}

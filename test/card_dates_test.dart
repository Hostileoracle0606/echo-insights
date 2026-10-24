import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/card_dates.dart';

void main() {
  test('shortDay is weekday, month and day', () {
    expect(shortDay(DateTime(2026, 10, 23, 21, 14)), 'Fri, Oct 23');
    expect(shortDay(DateTime(2026, 1, 4)), 'Sun, Jan 4');
  });

  test('monthDay is month and day', () {
    expect(monthDay(DateTime(2026, 10, 30)), 'Oct 30');
    expect(monthDay(DateTime(2026, 5, 1)), 'May 1');
  });

  group('askWhen', () {
    final friday = DateTime(2026, 10, 23, 17, 42);

    test('this week by weekday', () {
      expect(askWhen(friday, DateTime(2026, 10, 24)), 'ask tomorrow');
      expect(askWhen(friday, DateTime(2026, 10, 27)), 'ask Tuesday');
      expect(askWhen(friday, DateTime(2026, 10, 23)), 'ask today');
    });

    test('a week or more out as next or by date', () {
      expect(askWhen(friday, DateTime(2026, 10, 30)), 'ask next Friday');
      expect(askWhen(friday, DateTime(2026, 11, 4)), 'ask next Wednesday');
      expect(askWhen(friday, DateTime(2026, 11, 6)), 'ask Nov 6');
    });

    test('past due by date', () {
      expect(askWhen(friday, DateTime(2026, 10, 20)), 'ask Oct 20');
    });
  });
}

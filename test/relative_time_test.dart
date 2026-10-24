import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/relative_time.dart';

void main() {
  final now = DateTime(2026, 4, 28, 12);

  test('formats sub-minute, minutes, hours, days', () {
    expect(
      relativeTime(now.subtract(const Duration(seconds: 30)), now: now),
      'just now',
    );
    expect(
      relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
      '5m ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(hours: 2)), now: now),
      '2h ago',
    );
    expect(
      relativeTime(now.subtract(const Duration(days: 3)), now: now),
      '3d ago',
    );
  });

  test('falls back to Mon D beyond a week', () {
    expect(relativeTime(DateTime(2026, 4, 18), now: now), 'Apr 18');
  });

  group('spokenWhen', () {
    // Friday 2026-10-23, 3pm local.
    final friday = DateTime(2026, 10, 23, 15);
    String when(DateTime at) => spokenWhen(at, now: friday);

    test('names the day with a spoken-style hint', () {
      expect(when(DateTime(2026, 10, 23, 9)), 'Fri, Oct 23 (today)');
      expect(when(DateTime(2026, 10, 22, 23)), 'Thu, Oct 22 (yesterday)');
      expect(when(DateTime(2026, 10, 19, 8)), 'Mon, Oct 19 (this week)');
      expect(when(DateTime(2026, 10, 16, 17)), 'Fri, Oct 16 (last week)');
      expect(when(DateTime(2026, 10, 12)), 'Mon, Oct 12 (last week)');
      expect(when(DateTime(2026, 10, 11)), 'Sun, Oct 11 (2 weeks ago)');
      expect(when(DateTime(2026, 9, 28)), 'Mon, Sep 28 (3 weeks ago)');
      expect(when(DateTime(2026, 9, 10)), 'Thu, Sep 10 (last month)');
      expect(when(DateTime(2026, 6, 1)), 'Mon, Jun 1 (4 months ago)');
    });

    test('adds the year once it differs', () {
      expect(when(DateTime(2025, 12, 31)), 'Wed, Dec 31, 2025 (10 months ago)');
      expect(when(DateTime(2025, 6, 2)), 'Mon, Jun 2, 2025 (over a year ago)');
    });

    test('reads UTC instants in local time', () {
      final local = DateTime(2026, 10, 16, 17);
      expect(when(local.toUtc()), 'Fri, Oct 16 (last week)');
    });
  });
}

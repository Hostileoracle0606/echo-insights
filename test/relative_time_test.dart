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
}

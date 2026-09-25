// Each warm-up costs a runtime call and holds a Gemini Live connection, and a
// standby socket must be replaced before Gemini's ~10 minute connection
// limit. The budget caps warm-ups for an idle notebook: the first warm plus
// two refreshes, then cold until the user touches the screen again.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/warm_budget.dart';

void main() {
  test('allows the first warm and two refreshes, then goes cold', () {
    final budget = WarmBudget();
    expect(budget.tryConsume(), isTrue);
    expect(budget.tryConsume(), isTrue);
    expect(budget.tryConsume(), isTrue);
    expect(budget.tryConsume(), isFalse);
    expect(budget.exhausted, isTrue);
  });

  test('user interaction refills it', () {
    final budget = WarmBudget(maxWarms: 1);
    expect(budget.tryConsume(), isTrue);
    expect(budget.tryConsume(), isFalse);
    budget.refill();
    expect(budget.tryConsume(), isTrue);
  });

  test('refreshes land before Gemini\'s connection limit', () {
    expect(WarmBudget.refreshAfter, lessThan(const Duration(minutes: 10)));
    // Three warms cover roughly the 30-minute credential lifetime.
    expect(WarmBudget.refreshAfter * 3, greaterThan(const Duration(minutes: 25)));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/context_rebuild_policy.dart';

final t0 = DateTime.utc(2026, 11, 21, 12);

const idle = FloorState(
  live: true,
  agentSpeaking: false,
  userSpeaking: false,
  awaitingReply: false,
  reconnecting: false,
  offTheRecord: false,
);

ContextRebuildPolicy policy({
  int maxTurns = 4,
  Duration maxAge = const Duration(minutes: 10),
  Duration minInterval = const Duration(minutes: 2),
}) =>
    ContextRebuildPolicy(
      ContextRebuildConfig(
        maxTurns: maxTurns,
        maxAge: maxAge,
        minInterval: minInterval,
      ),
      startedAt: t0,
    );

void main() {
  test('no rebuild until the turn budget is spent', () {
    final p = policy();
    for (var i = 0; i < 3; i++) {
      p.turnCompleted();
    }
    expect(p.check(t0.add(const Duration(minutes: 3)), idle), isNull);
    p.turnCompleted();
    expect(
      p.check(t0.add(const Duration(minutes: 3)), idle),
      RebuildReason.turnBudget,
    );
  });

  test('the session age forces a rebuild even with few turns', () {
    final p = policy()..turnCompleted();
    expect(p.check(t0.add(const Duration(minutes: 9)), idle), isNull);
    expect(
      p.check(t0.add(const Duration(minutes: 10)), idle),
      RebuildReason.maxAge,
    );
  });

  test('never rebuilds while anyone has the floor or the session is busy', () {
    final p = policy();
    for (var i = 0; i < 4; i++) {
      p.turnCompleted();
    }
    final now = t0.add(const Duration(minutes: 3));
    final busy = <String, FloorState>{
      'not live': idle.copyWith(live: false),
      'Lumen speaking': idle.copyWith(agentSpeaking: true),
      'user speaking': idle.copyWith(userSpeaking: true),
      'reply awaited': idle.copyWith(awaitingReply: true),
      'reconnecting': idle.copyWith(reconnecting: true),
      // Rebuilt context comes only from saved turns: off-record talk would vanish.
      'off the record': idle.copyWith(offTheRecord: true),
    };
    for (final entry in busy.entries) {
      expect(p.check(now, entry.value), isNull, reason: entry.key);
    }
    expect(p.check(now, idle), RebuildReason.turnBudget);
  });

  test('a rebuild resets the budget and the age', () {
    final p = policy();
    for (var i = 0; i < 4; i++) {
      p.turnCompleted();
    }
    final rebuiltAt = t0.add(const Duration(minutes: 3));
    p.rebuilt(rebuiltAt);
    expect(p.turnsSinceRebuild, 0);
    expect(p.check(rebuiltAt.add(const Duration(minutes: 9)), idle), isNull);
    expect(
      p.check(rebuiltAt.add(const Duration(minutes: 10)), idle),
      RebuildReason.maxAge,
    );
  });

  test('a turn budget spent soon after a rebuild waits for the minimum interval',
      () {
    final p = policy();
    p.rebuilt(t0);
    for (var i = 0; i < 4; i++) {
      p.turnCompleted();
    }
    expect(p.check(t0.add(const Duration(seconds: 90)), idle), isNull);
    expect(
      p.check(t0.add(const Duration(minutes: 2)), idle),
      RebuildReason.turnBudget,
    );
  });

  test('defaults rebuild within Gemini audio limits and keep replay complete',
      () {
    const config = ContextRebuildConfig();
    // Compression is off when rebuilding, so age must stay under ~15 minutes.
    expect(config.maxAge, lessThan(const Duration(minutes: 15)));
    // Every turn since the last rebuild still fits resumeContext's 20 turns.
    expect(config.maxTurns, lessThanOrEqualTo(20));
  });

  test('config reads overrides and falls back on invalid values', () {
    expect(ContextRebuildConfig.fromDefines(maxTurns: '4').maxTurns, 4);
    expect(
      ContextRebuildConfig.fromDefines(maxTurns: 'x').maxTurns,
      const ContextRebuildConfig().maxTurns,
    );
    expect(
      ContextRebuildConfig.fromDefines(maxTurns: '0').maxTurns,
      const ContextRebuildConfig().maxTurns,
    );
  });
}

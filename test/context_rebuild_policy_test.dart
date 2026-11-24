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

  test('defaults rebuild within Gemini audio limits, on tokens not turns (EC-05)',
      () {
    const config = ContextRebuildConfig();
    // Compression is off when rebuilding, so age must stay under ~15 minutes.
    expect(config.maxAge, lessThan(const Duration(minutes: 15)));
    expect(config.maxTurns, isNull, reason: 'turn count is only an override');
    expect(config.maxTokens, 6000);
  });

  test('config reads overrides and falls back on invalid values', () {
    expect(ContextRebuildConfig.fromDefines(maxTurns: '4').maxTurns, 4);
    expect(ContextRebuildConfig.fromDefines(maxTurns: 'x').maxTurns, isNull);
    expect(ContextRebuildConfig.fromDefines(maxTurns: '0').maxTurns, isNull);
    expect(ContextRebuildConfig.fromDefines(maxTokens: '2500').maxTokens, 2500);
    expect(ContextRebuildConfig.fromDefines(maxTokens: 'x').maxTokens, 6000);
  });

  test('the token budget triggers a rebuild at a pause (EC-05)', () {
    final p = ContextRebuildPolicy(
      const ContextRebuildConfig(maxTokens: 100),
      startedAt: t0,
    );
    final later = t0.add(const Duration(minutes: 1));
    p.turnCompleted(tokens: 60);
    expect(p.check(later, idle), isNull);
    p.turnCompleted(tokens: 50);
    expect(p.tokensSinceRebuild, 110);
    expect(p.check(later, idle.copyWith(agentSpeaking: true)), isNull,
        reason: 'only at a pause');
    expect(p.check(later, idle), RebuildReason.tokenBudget);
    p.rebuilt(later);
    expect(p.tokensSinceRebuild, 0);
  });

  test('a requested rebuild (a confirmed correction) waits for the next pause',
      () {
    final p = ContextRebuildPolicy(const ContextRebuildConfig(), startedAt: t0);
    p.request(RebuildReason.correction);
    final later = t0.add(const Duration(seconds: 5));
    expect(p.check(later, idle.copyWith(userSpeaking: true)), isNull);
    expect(p.check(later, idle), RebuildReason.correction);
    p.rebuilt(later);
    expect(p.check(later, idle), isNull, reason: 'done once');
  });

  test('the window Gemini reports counts from the first report after a rebuild',
      () {
    final p = ContextRebuildPolicy(
      const ContextRebuildConfig(maxTokens: 1000),
      startedAt: t0,
    );
    final later = t0.add(const Duration(minutes: 1));
    p.observedWindow(5000); // system instruction and seed context
    expect(p.tokensSinceRebuild, 0);
    p.turnCompleted(tokens: 10);
    p.observedWindow(5900);
    expect(p.tokensSinceRebuild, 900, reason: 'the report outweighs the estimate');
    expect(p.check(later, idle), isNull);
    p.observedWindow(6100);
    expect(p.check(later, idle), RebuildReason.tokenBudget);
    p.rebuilt(later);
    p.observedWindow(5200);
    expect(p.tokensSinceRebuild, 0, reason: 'a new baseline after a rebuild');
  });
}

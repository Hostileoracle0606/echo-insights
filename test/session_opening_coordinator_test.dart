import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/session_opening_coordinator.dart';

void main() {
  group('SessionOpeningCoordinator', () {
    test('Lumen holds the floor until the greeting has been heard', () {
      final coordinator = SessionOpeningCoordinator();
      expect(coordinator.inProgress, isTrue);
      expect(coordinator.acceptsUserAudio, isFalse);

      expect(coordinator.markOpeningHeard(), isTrue);
      expect(coordinator.acceptsUserAudio, isTrue);
      expect(coordinator.inProgress, isFalse);
      expect(coordinator.markOpeningHeard(), isFalse);
    });

    test('the greeting is started once per session', () {
      final coordinator = SessionOpeningCoordinator();
      expect(coordinator.claimGreeting(), isTrue);
      expect(coordinator.claimGreeting(), isFalse);
    });

    test('a greeting that cannot play hands the floor over at once', () {
      // No playback path (e.g. the simulator's audio init timed out):
      // nothing will ever drain, so the caller marks it heard immediately.
      final coordinator = SessionOpeningCoordinator();
      expect(coordinator.markOpeningHeard(), isTrue);
      expect(coordinator.claimGreeting(), isFalse,
          reason: 'too late to greet once the floor is the user\'s');
    });
  });
}

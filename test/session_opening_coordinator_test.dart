import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/session_opening_coordinator.dart';

void main() {
  group('SessionOpeningCoordinator', () {
    test('requests one opening after setup and playback are ready', () {
      final coordinator = SessionOpeningCoordinator();

      expect(coordinator.markSetupComplete(), isFalse);
      expect(coordinator.acceptsUserAudio, isFalse);
      expect(coordinator.markPlaybackAttemptFinished(), isTrue);

      expect(coordinator.markSetupComplete(), isFalse);
      expect(coordinator.markPlaybackAttemptFinished(), isFalse);
    });

    test('works when playback becomes ready before setup completes', () {
      final coordinator = SessionOpeningCoordinator();

      expect(coordinator.markPlaybackAttemptFinished(), isFalse);
      expect(coordinator.markSetupComplete(), isTrue);
    });

    test('blocks user audio until the opening turn completes', () {
      final coordinator = SessionOpeningCoordinator();

      expect(coordinator.markTurnComplete(), isFalse);
      expect(coordinator.acceptsUserAudio, isFalse);

      coordinator.markSetupComplete();
      expect(coordinator.markPlaybackAttemptFinished(), isTrue);
      expect(coordinator.acceptsUserAudio, isFalse);

      expect(coordinator.markTurnComplete(), isTrue);
      expect(coordinator.markTurnComplete(), isFalse);
    });

    test('opens the mic only once the opening has been heard', () {
      // Gemini streams faster than real time: its turn completes while the
      // opening is still playing. Opening the mic then would let Lumen's own
      // voice (and the user talking over it) into the next turn.
      final coordinator = SessionOpeningCoordinator()
        ..markSetupComplete()
        ..markPlaybackAttemptFinished();
      expect(coordinator.inProgress, isTrue);

      expect(coordinator.markOpeningHeard(), isFalse,
          reason: 'playback ending before the turn completes is not the end');
      expect(coordinator.acceptsUserAudio, isFalse);

      coordinator.markTurnComplete();
      expect(coordinator.acceptsUserAudio, isFalse);
      expect(coordinator.inProgress, isTrue);

      expect(coordinator.markOpeningHeard(), isTrue);
      expect(coordinator.acceptsUserAudio, isTrue);
      expect(coordinator.inProgress, isFalse);
      expect(coordinator.markOpeningHeard(), isFalse);
    });
  });
}

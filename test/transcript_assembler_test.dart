import 'package:flutter_test/flutter_test.dart';

import 'package:lumen/logic/transcript_assembler.dart';
import 'package:lumen/logic/turn_state.dart';

void main() {
  group('TranscriptAssembler', () {
    test('incremental chunks produce ONE replaceable interim transcript', () {
      final a = TranscriptAssembler();

      final first = a.userChunk('I work at Acme.');
      final second = a.userChunk(' My manager is Sarah.');

      expect(first, hasLength(1));
      expect((first.first as InterimTranscript).text, 'I work at Acme.');
      // The second chunk replaces; it does not queue a second durable turn.
      expect((second.first as InterimTranscript).text, 'I work at Acme. My manager is Sarah.');
    });

    test('a provider interim replacement overwrites the accumulated buffer', () {
      final a = TranscriptAssembler();
      a.userChunk('I work at Acne');

      final events = a.userInterim('I work at Acme');
      expect((events.first as InterimTranscript).text, 'I work at Acme');

      // A following chunk extends the corrected text, not the old one.
      expect((a.userChunk('.').first as InterimTranscript).text, 'I work at Acme.');
    });

    test('a finished transcription emits the whole accumulated turn', () {
      final a = TranscriptAssembler();
      a.userChunk('I work at ');

      final events = a.userFinal('Acme.');
      expect(events, hasLength(1));
      expect((events.first as FinalTranscript).text, 'I work at Acme.');
    });

    test('the assistant answering closes the user turn exactly once', () {
      final a = TranscriptAssembler();
      a.userChunk('Who is my manager?');

      final events = a.assistantChunk('You said Sarah');
      expect(events.whereType<TurnCompleted>(), hasLength(1));
      expect(events.whereType<TurnCompleted>().first.speaker, Speaker.user);

      final second = a.assistantChunk(' is your manager.');
      expect(second.whereType<TurnCompleted>(), isEmpty);
    });

    test('turnComplete closes the assistant turn and resets buffers', () {
      final a = TranscriptAssembler();
      a.userChunk('Hello');
      a.assistantChunk('Hi there.');

      final events = a.turnComplete();
      expect(events.whereType<TurnCompleted>().last.speaker, Speaker.assistant);

      final next = a.assistantChunk('Next answer.');
      expect((next.first as InterimTranscript).text, 'Next answer.');
    });

    test('a user turn the assistant never answered still completes', () {
      final a = TranscriptAssembler();
      a.userChunk('Just thinking out loud.');

      final speakers = a.turnComplete().whereType<TurnCompleted>().map((e) => e.speaker);
      expect(speakers, [Speaker.user, Speaker.assistant]);
    });

    test('the heard-character watermark passes through on interruption', () {
      final a = TranscriptAssembler();
      a.assistantChunk('You mentioned Acme. Your sister Mia lives in Oslo.');

      final events = a.interrupted(19);
      expect((events.first as AssistantInterrupted).heardChars, 19);
    });

    test('an unknown heard boundary is reported as unknown, not guessed', () {
      final a = TranscriptAssembler();
      a.assistantChunk('You mentioned Acme.');

      expect((a.interrupted(null).first as AssistantInterrupted).heardChars, isNull);
    });
  });
}

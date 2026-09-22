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
      expect((second.first as InterimTranscript).text,
          'I work at Acme. My manager is Sarah.');
    });

    test('a provider interim replacement overwrites the accumulated buffer',
        () {
      final a = TranscriptAssembler();
      a.userChunk('I work at Acne');

      final events = a.userInterim('I work at Acme');
      expect((events.first as InterimTranscript).text, 'I work at Acme');

      // A following chunk extends the corrected text, not the old one.
      expect((a.userChunk('.').first as InterimTranscript).text,
          'I work at Acme.');
    });

    test('a finished transcription emits the whole accumulated turn', () {
      final a = TranscriptAssembler();
      a.userChunk('I work at ');

      final events = a.userFinal('Acme.');
      expect(events, hasLength(1));
      expect((events.first as FinalTranscript).text, 'I work at Acme.');
    });

    test('a late user final keeps the prefix parked at turn completion', () {
      final a = TranscriptAssembler();
      a.userChunk('I work at ');

      final closing = a.assistantChunk('Tell me more.');
      final completed = closing.whereType<TurnCompleted>().single;
      expect(completed.transcriptGeneration, isNotNull);

      final events = a.userFinal('Acme.');
      expect((events.single as FinalTranscript).text, 'I work at Acme.');
    });

    test('a late assistant final keeps the prefix parked at turn completion',
        () {
      final a = TranscriptAssembler();
      a.assistantChunk('You work at ');

      final completed = a.turnComplete().whereType<TurnCompleted>().last;
      expect(completed.transcriptGeneration, isNotNull);

      final events = a.assistantFinal('Acme.');
      expect((events.single as FinalTranscript).text, 'You work at Acme.');
    });

    test('a final after its fallback deadline is discarded', () {
      final a = TranscriptAssembler();
      a.assistantChunk('Fallback text.');
      final completed = a.turnComplete().whereType<TurnCompleted>().last;

      a.expirePending(Speaker.assistant, completed.transcriptGeneration!);
      expect(a.assistantFinal(' Late duplicate.'), isEmpty);

      expect(
        (a.assistantChunk('Next answer.').single as InterimTranscript).text,
        'Next answer.',
      );
    });

    test('an expired turn cannot consume the next active turn final', () {
      final a = TranscriptAssembler();
      a.assistantChunk('Old answer.');
      final old = a.turnComplete().whereType<TurnCompleted>().last;
      a.assistantChunk('New answer');

      a.expirePending(Speaker.assistant, old.transcriptGeneration!);
      final events = a.assistantFinal(' complete.');
      expect(
        (events.single as FinalTranscript).text,
        'New answer complete.',
      );
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

      final speakers =
          a.turnComplete().whereType<TurnCompleted>().map((e) => e.speaker);
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

      expect((a.interrupted(null).first as AssistantInterrupted).heardChars,
          isNull);
    });

    test('an interrupted assistant buffer is not parked for a late final', () {
      final a = TranscriptAssembler();
      a.assistantChunk('Text that may not have been heard.');
      a.interrupted(null);

      final completed = a.turnComplete().whereType<TurnCompleted>().last;
      expect(completed.transcriptGeneration, isNull);
      expect(a.assistantFinal(' trailing text'), isEmpty);
    });
  });
}

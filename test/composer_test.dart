// LM-12: the composer that fills the pill's slot — quick replies on top, then
// mic · view · field · Send.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/composer.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Calls {
  final sent = <String>[];
  final views = <JournalView>[];
  int voice = 0;
  bool accept = true;
}

Future<_Calls> _pump(
  WidgetTester tester, {
  List<String> quickReplies = const [],
  JournalView view = JournalView.graph,
}) async {
  final calls = _Calls();
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 358,
            child: Composer(
              view: view,
              quickReplies: quickReplies,
              onSend: (text) {
                if (calls.accept) calls.sent.add(text);
                return calls.accept;
              },
              onVoiceTap: () => calls.voice++,
              onViewChanged: calls.views.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return calls;
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('the field takes focus as the composer opens', (tester) async {
    await _pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('Send is disabled until there is something to send',
      (tester) async {
    final calls = await _pump(tester);

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    expect(calls.sent, isEmpty);

    await tester.enterText(find.byType(TextField), 'Maya signed off.');
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(isButton: true, isEnabled: true),
    );
  });

  testWidgets('Send sends the text and clears the field for the next one',
      (tester) async {
    final calls = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'Maya signed off.');
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();

    expect(calls.sent, ['Maya signed off.']);
    expect(_fieldText(tester), isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
      reason: 'the keyboard stays up, as in a chat',
    );
  });

  testWidgets('Return sends too', (tester) async {
    final calls = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'Second thought.');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(calls.sent, ['Second thought.']);
    expect(_fieldText(tester), isEmpty);
  });

  testWidgets('a send that was not accepted keeps the text', (tester) async {
    final calls = await _pump(tester)..accept = false;
    await tester.enterText(find.byType(TextField), 'Not yet.');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pump();

    expect(_fieldText(tester), 'Not yet.');
    expect(calls.sent, isEmpty);
  });

  testWidgets('the mic switches back to voice', (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Switch to voice'));
    expect(calls.voice, 1);
  });

  testWidgets('the view button asks for the other view', (tester) async {
    final calls = await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Show transcript'));
    expect(calls.views, [JournalView.transcript]);

    final again = await _pump(tester, view: JournalView.transcript);
    await tester.tap(find.bySemanticsLabel('Show graph'));
    expect(again.views, [JournalView.graph]);
  });

  testWidgets('Just talk has no quick replies', (tester) async {
    await _pump(tester);
    expect(find.byKey(Composer.quickRepliesKey), findsNothing);
  });

  testWidgets('a quick reply sends itself', (tester) async {
    final calls = await _pump(
      tester,
      quickReplies: const ['Same as last week', 'Skip'],
    );

    expect(find.byKey(Composer.quickRepliesKey), findsOneWidget);
    await tester.tap(find.text('Same as last week'));
    expect(calls.sent, ['Same as last week']);
  });

  testWidgets('every target is at least 44pt', (tester) async {
    await _pump(tester, quickReplies: const ['Skip']);

    for (final label in ['Switch to voice', 'Show transcript', 'Send', 'Skip']) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
    }
    expect(tester.getSize(find.byType(TextField)).height,
        greaterThanOrEqualTo(44));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/conversation_policy.dart';
import 'package:lumen/logic/memory_correction.dart';
import 'package:lumen/providers/journal_provider.dart';

// EC-07: what the user disputes becomes a pending correction; the database
// builds the read-back; nothing changes until the user says yes.

void main() {
  test('spoken values become typed changes', () {
    expect(correctionChange({'value': '7k'}), {'valueNum': 7000});
    expect(correctionChange({'value': '7,000', 'unit': 'USD'}), {'valueNum': 7000, 'unit': 'USD'});
    expect(correctionChange({'value': '12.5'}), {'valueNum': 12.5});
    expect(correctionChange({'value': 'the 2nd'}), {'valueText': 'the 2nd'});
    expect(correctionChange({'date': '2026-11-18'}), {'eventAt': '2026-11-18T12:00:00Z'});
    expect(correctionChange({'status': 'planned'}), {'status': 'proposed'});
    expect(correctionChange({'status': 'done'}), {'status': 'confirmed'});
    expect(correctionChange({'status': 'called off'}), {'status': 'cancelled'});
    expect(correctionChange({'belongs_to': 'Priya'}), {'entity': 'Priya'});
    expect(correctionChange({'remove': true}), {'remove': true});
  });

  test('nothing to change is not a correction', () {
    expect(correctionChange({}), isNull);
    expect(correctionChange({'date': 'last week'}), isNull);
    expect(correctionChange({'status': 'maybe'}), isNull);
  });

  test('Lumen has a correct_memory tool with propose, confirm and reject', () {
    final declarations =
        JournalNotifier.liveTools.single['function_declarations'] as List;
    final tool = declarations
        .cast<Map>()
        .firstWhere((d) => d['name'] == 'correct_memory');
    final action = ((tool['parameters'] as Map)['properties'] as Map)['action'] as Map;
    expect(action['enum'], ['propose', 'confirm', 'reject']);
  });

  test('the prompt says to read back first and change nothing without a yes', () {
    expect(geminiLiveSystemInstruction, contains('correct_memory'));
    expect(geminiLiveSystemInstruction,
        contains('Never say it is fixed until confirm returns done'));
  });

  test('a new value the user simply states is not a correction (EC-10 run)', () {
    // Found in the Simulator: "My savings goal is 8k now" made Lumen call
    // correct_memory, then say it "didn't have the number stored".
    final declarations =
        JournalNotifier.liveTools.single['function_declarations'] as List;
    final tool = declarations.cast<Map>().firstWhere((d) => d['name'] == 'correct_memory');
    expect(tool['description'], contains('is not a correction'));
    expect(geminiLiveSystemInstruction, contains('is not a correction'));
  });
}

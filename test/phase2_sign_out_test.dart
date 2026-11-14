// Phase 2 integration: what LM-55 (name map), LM-57 (shared log), LM-63
// (forgotten names) and LM-58 (sign-in methods, account switches) each keep
// on the phone is erased together, and also when the account changes with no
// sign-out in between.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/logic/forget_redaction.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/providers/forget_redactor_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/pseudonym_provider.dart';
import 'package:lumen/providers/shared_log_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/shared_log.dart';

import 'support/pseudonyms.dart';

class _NoBriefs implements SessionBriefService {
  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: false, brief: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late MemoryStore forgottenStore;
  late MemoryStore mapStore;
  late ForgetRedactor redactor;
  late SharedLog log;
  late OpeningPrep prep;
  late ProviderContainer container;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('phase2_sign_out');
    forgottenStore = MemoryStore();
    mapStore = MemoryStore();
    redactor = ForgetRedactor(store: forgottenStore, ownerId: () => 'apple-1');
    await redactor.ensureLoaded();
    redactor.add('priya-raman', ['Priya Raman']);
    await redactor.flush();
    final names = PseudonymService(ownerId: () => 'apple-1', store: mapStore);
    await names.sync([
      const PseudonymEntity(
        id: 'sam',
        name: 'Samantha',
        kind: PseudonymKind.person,
        aliases: [],
      ),
    ]);
    expect(mapStore.saved, isNotNull);
    log = SharedLog(
      directoryProvider: () async => dir,
      protect: (path, level) async {},
      excludeFromBackup: (path) async {},
    );
    await log.record('8e03b8f4-4f20-4df3-8398-d854adc32b14', SharedKind.extraction, {'text': 'hello'});
    prep = OpeningPrep(_NoBriefs())..markNewAccount();
    container = ProviderContainer(overrides: [
      openingPrepProvider.overrideWithValue(prep),
      forgetRedactorProvider.overrideWithValue(redactor),
      pseudonymServiceProvider.overrideWithValue(names),
      sharedLogProvider.overrideWithValue(log),
    ]);
    addTearDown(container.dispose);
    container.read(forgottenThisRunProvider).add('priya-raman');
    expect(forgottenStore.saved, isNotNull);
    expect(await log.readAll(), isNotEmpty);
    expect(prep.knownNewAccount, isTrue);
  });

  tearDown(() async {
    await pumpEventQueue();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> expectEverythingGone() async {
    await pumpEventQueue();
    expect(container.read(forgottenThisRunProvider), isEmpty);
    expect(forgottenStore.saved, isNull);
    expect(mapStore.saved, isNull);
    expect(redactor.isEmpty, isTrue);
    expect(await log.readAll(), isEmpty);
    expect(prep.knownNewAccount, isFalse);
  }

  test('the cleanup erases all four accounts-bound stores together', () async {
    container.read(signedOutCleanupProvider)();
    await expectEverythingGone();
  });

  test('a different account arriving with no sign-out in between cleans up',
      () async {
    final binding = VoiceServicesBinding(
      credentials: LiveCredentials(fetch: () async => throw StateError('x')),
      audioOutput: AudioOutput(),
      runtimeConfigured: false,
      onSignedOut: container.read(signedOutCleanupProvider),
    );
    binding.signedInChanged(true, userId: 'apple-1');
    binding.signedInChanged(true, userId: 'apple-1');
    expect(forgottenStore.saved, isNotNull, reason: 'same account: kept');
    binding.signedInChanged(true, userId: 'email-2');
    await expectEverythingGone();
    binding.signedInChanged(false);
  });

  test('linking Apple (same user id, new token) keeps the account\'s data',
      () async {
    var cleaned = 0;
    final binding = VoiceServicesBinding(
      credentials: LiveCredentials(fetch: () async => throw StateError('x')),
      audioOutput: AudioOutput(),
      runtimeConfigured: false,
      onSignedOut: () => cleaned += 1,
    );
    binding.signedInChanged(true, userId: 'u1');
    binding.signedInChanged(true, userId: 'u1');
    binding.signedInChanged(true);
    expect(cleaned, 0);
    binding.signedInChanged(false);
    expect(cleaned, 1);
  });
}

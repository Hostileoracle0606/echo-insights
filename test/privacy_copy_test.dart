// Copy guard for the privacy claims (LM-53): the files that carry them may
// never say what isn't true today.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/privacy/privacy_claims.dart';

const _files = [
  'lib/privacy/privacy_claims.dart',
  'lib/screens/privacy/who_hears_you_screen.dart',
  'src/routes/security.tsx',
];

const _banned = [
  'keeps nothing',
  'never stored',
  "can't read",
  'cannot read',
  'military-grade',
  'end-to-end',
];

void main() {
  for (final path in _files) {
    test('$path has no banned phrase', () {
      // Normalise curly quotes so "can’t read" can't slip past.
      final text = File(
        path,
      ).readAsStringSync().toLowerCase().replaceAll('’', "'");
      for (final phrase in _banned) {
        final offending =
            text.split('\n').where((l) => l.contains(phrase)).toList();
        expect(offending, isEmpty, reason: '"$phrase" in $path');
      }
    });
  }

  test('both Google claims avoid the banned phrases', () {
    for (final verified in [false, true]) {
      final claim = googleClaim(verified: verified).toLowerCase();
      for (final phrase in _banned) {
        expect(claim, isNot(contains(phrase)));
      }
    }
  });

  test('the web page repeats the iOS Google line word for word', () {
    final page = File('src/routes/security.tsx').readAsStringSync();
    expect(page, contains(googleClaim(verified: false)));
    expect(page, contains(googleDetail));
    expect(page, contains(awsClaim));
    expect(page, contains(reachClaim));
    expect(page, contains(phoneClaim));
    expect(page, contains(exportClaim));
    expect(page, contains(sharedLogClaim));
    expect(page, contains(supabaseClaim));
    expect(page, contains(usClaim));
    // Only the controls that are shipped; the rest stay off the page.
    for (final entry in gatedClaims.entries) {
      if (shipped.contains(entry.key)) {
        expect(page, contains(entry.value));
      } else {
        expect(page, isNot(contains(entry.value)),
            reason: '${entry.key} is not shipped');
      }
    }
  });

  // LM-56 (R24): names are swapped for the text model only, on the iPhone;
  // the live voice path and the spoken opening line carry real names.
  test('the Google detail says where names are swapped and where not', () {
    expect(googleDetail, contains('In the iPhone app'));
    expect(googleDetail, contains('made-up names'));
    expect(googleDetail, contains('your voice goes to Google live'));
    expect(googleDetail, contains('with names as you said them'));
    expect(googleDetail, contains("Google's voice with real names"));
    expect(googleDetail, contains('can still go through'));
    expect(googleDetail.toLowerCase(), isNot(contains('every name')));
  });

  test('the cache line does not promise an exact expiry', () {
    expect(awsClaim, contains('about a week'));
    expect(awsClaim, isNot(contains('7 days')));
  });

  // What the controls really do: transcripts keep the name for the user and
  // Lumen reads them redacted (LM-63), off the record still reaches Google,
  // and auto-forget leaves cards and memory.
  test('the shipped controls claim only what they do', () {
    final forget = gatedClaims[PrivacyFeature.forgetPerson]!;
    expect(forget, contains("Lumen won't bring them up again"));
    expect(forget, contains("they're gone from your maps"));
    expect(forget, contains('transcripts keep your words for you to read'));
    expect(forget, isNot(contains('may bring the name up')));
    expect(forget, contains('a nickname or a first name alone'));
    expect(forget, isNot(contains('leave your journal')));
    expect(gatedClaims[PrivacyFeature.offTheRecord]!, contains('Google'));
    expect(
      gatedClaims[PrivacyFeature.autoForget]!,
      contains('Cards and what Lumen remembers stay.'),
    );
  });

  // LM-45: dashboard SQL is not reliably logged, so the control is a written
  // log. LM-52: the export leaves out briefs and their audio.
  test('access claims promise a written log, not automatic logging', () {
    for (final claim in [supabaseClaim, usClaim]) {
      expect(claim, isNot(contains('and logged')));
    }
    expect(usClaim, contains('written log'));
    expect(usClaim, contains('security incident'));
    expect(usClaim, contains('Nothing technically stops us.'));
  });

  test('the export claim does not say everything', () {
    expect(exportClaim.toLowerCase(), isNot(contains('everything')));
    final page = File('src/routes/security.tsx').readAsStringSync();
    expect(page.toLowerCase(), isNot(contains('zip of everything')));
    expect(page, contains(exportClaim));
  });

  // R30: the device-list claim rests on hosted facts nobody has checked yet
  // (DELETE on auth.sessions, JWT expiry of an hour or less). It ships with
  // the checklist's staging check, not before.
  test('unverified claims stay off; the verified controls are shipped', () {
    expect(paidTierVerified, isFalse);
    expect(supabaseEncryptionVerified, isFalse);
    expect(shipped, {
      PrivacyFeature.forgetPerson,
      PrivacyFeature.offTheRecord,
      PrivacyFeature.autoForget,
    });
    expect(shipped, isNot(contains(PrivacyFeature.deviceList)));
  });

  test('the page has no wording the security review ruled out', () {
    final page = File('src/routes/security.tsx').readAsStringSync();
    expect(page, isNot(contains('rows from other accounts')));
    expect(page, isNot(contains('stops us yet')));
  });
}

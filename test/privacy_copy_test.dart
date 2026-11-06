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
    expect(page, contains(supabaseClaim));
    expect(page, contains(usClaim));
    for (final line in gatedClaims.values) {
      expect(page, contains(line));
    }
  });

  // What the controls really do: transcripts keep the name, off the record
  // still reaches Google, and auto-forget leaves cards and memory.
  test('the shipped controls claim only what they do', () {
    final forget = gatedClaims[PrivacyFeature.forgetPerson]!;
    expect(forget, contains('transcripts keep what you said'));
    expect(forget, contains('nickname'));
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

  test('unverified claims stay off; the three controls are shipped', () {
    expect(paidTierVerified, isFalse);
    expect(supabaseEncryptionVerified, isFalse);
    expect(shipped, PrivacyFeature.values.toSet());
  });

  test('the page has no wording the security review ruled out', () {
    final page = File('src/routes/security.tsx').readAsStringSync();
    expect(page, isNot(contains('rows from other accounts')));
    expect(page, isNot(contains('stops us yet')));
  });
}

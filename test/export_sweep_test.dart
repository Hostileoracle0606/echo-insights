// LM-52: shared exports are not deleted right after the share sheet closes
// (AirDrop may still be reading them); stale ones are swept later.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/markdown_export.dart';

void main() {
  late Directory dir;
  final now = DateTime(2026, 11, 4, 12);

  setUp(() => dir = Directory.systemTemp.createTempSync('sweep'));
  tearDown(() => dir.deleteSync(recursive: true));

  File make(String name, Duration age) {
    final f = File('${dir.path}/$name')..writeAsStringSync('x');
    f.setLastModifiedSync(now.subtract(age));
    return f;
  }

  test('removes old exports and vaults; keeps fresh and other files', () async {
    final old = make('lumen-journal-2026-11-03.zip', const Duration(hours: 2));
    final fresh =
        make('lumen-journal-2026-11-04.zip', const Duration(minutes: 5));
    final oldVault =
        make('Lumen Vault-2026-10-01.zip', const Duration(days: 3));
    final freshVault =
        make('Lumen Vault-2026-11-04.zip', const Duration(minutes: 10));
    final notZip = make('lumen-notes.txt', const Duration(days: 3));
    final unrelated = make('cache.zip', const Duration(days: 3));

    await sweepStaleExports(directory: dir, now: now);

    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(oldVault.existsSync(), isFalse);
    expect(freshVault.existsSync(), isTrue);
    expect(notZip.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
  });

  test('a missing directory is not an error', () async {
    await sweepStaleExports(directory: Directory('${dir.path}/nope'));
  });
}

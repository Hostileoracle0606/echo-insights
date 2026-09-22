import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/env.dart';

void main() {
  test('assertConfigured names every missing value', () {
    dotenv.testLoad(fileInput: '');
    expect(
      Env.assertConfigured,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('SUPABASE_URL'),
            contains('SUPABASE_ANON_KEY'),
            contains('NOTEBOOK_RUNTIME_URL'),
          ),
        ),
      ),
    );
  });

  test('assertConfigured names only the values still missing', () {
    dotenv.testLoad(
      fileInput: 'SUPABASE_URL=https://example.supabase.co\n'
          'SUPABASE_ANON_KEY=anon-key\n',
    );
    expect(
      Env.assertConfigured,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('NOTEBOOK_RUNTIME_URL'),
            isNot(contains('SUPABASE_URL')),
            isNot(contains('SUPABASE_ANON_KEY')),
          ),
        ),
      ),
    );
  });

  test('assertConfigured passes with values injected through dotenv.testLoad',
      () {
    dotenv.testLoad(
      fileInput: 'SUPABASE_URL=https://example.supabase.co\n'
          'SUPABASE_ANON_KEY=anon-key\n'
          'NOTEBOOK_RUNTIME_URL=https://runtime.example.com\n',
    );
    expect(Env.assertConfigured, returnsNormally);
  });
}

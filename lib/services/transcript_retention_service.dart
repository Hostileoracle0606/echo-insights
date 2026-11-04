import 'package:supabase_flutter/supabase_flutter.dart';

typedef RetentionRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);
typedef RetentionRead = Future<Object?> Function();

/// The days a transcript is kept (LM-51): null keeps it forever. Only these
/// values are accepted by the server too.
const transcriptRetentionChoices = <int?>[null, 90, 30, 7];

/// How long Lumen keeps transcripts. Reads `profiles.transcript_retention_days`
/// (owner-only RLS) and writes through `set_transcript_retention`, which
/// validates the value. Nothing here touches or logs what a transcript held.
class TranscriptRetentionService {
  TranscriptRetentionService(SupabaseClient client)
      : _rpc = ((function, params) => client.rpc(function, params: params)),
        _read = (() async {
          final row = await client
              .from('profiles')
              .select('transcript_retention_days')
              .maybeSingle();
          return row?['transcript_retention_days'];
        });

  TranscriptRetentionService.withFunctions({
    required RetentionRpc rpc,
    required RetentionRead read,
  })  : _rpc = rpc,
        _read = read;

  final RetentionRpc _rpc;
  final RetentionRead _read;

  /// The current setting; null means forever.
  Future<int?> current() async => (await _read()) as int?;

  Future<void> set(int? days) async {
    await _rpc('set_transcript_retention', {'p_days': days});
  }
}

import 'package:supabase_flutter/supabase_flutter.dart';

typedef RetentionRpc = Future<Object?> Function(
  String function,
  Map<String, dynamic> params,
);
typedef RetentionRead = Future<Map<String, dynamic>?> Function();

/// The days a transcript is kept (LM-51): null keeps it forever. Only these
/// values are accepted by the server too.
const transcriptRetentionChoices = <int?>[null, 90, 30, 7];

/// How long Lumen keeps transcripts. Reads the profile's retention columns
/// (owner-only RLS) and writes through `set_transcript_retention`, which
/// validates the value. Nothing here touches or logs what a transcript held.
class TranscriptRetentionService {
  TranscriptRetentionService(SupabaseClient client)
      : _rpc = ((function, params) => client.rpc(function, params: params)),
        _read = (() async {
          final row = await client
              .from('profiles')
              .select(
                  'transcript_retention_days, transcript_retention_offered_at')
              .maybeSingle();
          return row;
        });

  TranscriptRetentionService.withFunctions({
    required RetentionRpc rpc,
    required RetentionRead read,
  })  : _rpc = rpc,
        _read = read;

  final RetentionRpc _rpc;
  final RetentionRead _read;

  /// The current setting; null means forever.
  Future<int?> current() async =>
      (await _read())?['transcript_retention_days'] as int?;

  /// Whether the one-time choice has already been shown on this account.
  Future<bool> wasOffered() async =>
      (await _read())?['transcript_retention_offered_at'] != null;

  /// Records that the choice was shown (keeps the first time).
  Future<void> markOffered() async {
    await _rpc('mark_transcript_retention_offered', const {});
  }

  Future<void> set(int? days) async {
    await _rpc('set_transcript_retention', {'p_days': days});
  }
}

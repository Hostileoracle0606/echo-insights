import 'package:supabase_flutter/supabase_flutter.dart';

/// EC-07: the correction flow's RPCs. propose returns the read-back sentence
/// the database built; apply changes the fact (only after the user's yes);
/// reject records a "no".
class MemoryCorrectionService {
  MemoryCorrectionService(this._client);
  final SupabaseClient _client;

  Future<Map<String, dynamic>> propose({
    required String about,
    String? attribute,
    required Map<String, dynamic> change,
  }) async =>
      _map(await _client.rpc('propose_memory_correction', params: {
        'p_about': about,
        'p_attribute': attribute,
        'p_change': change,
      }));

  Future<Map<String, dynamic>> apply(String correctionId) async => _map(
      await _client.rpc('apply_memory_correction', params: {'p_correction_id': correctionId}));

  Future<Map<String, dynamic>> reject(String correctionId) async => _map(
      await _client.rpc('reject_memory_correction', params: {'p_correction_id': correctionId}));

  static Map<String, dynamic> _map(Object? data) =>
      data is Map ? data.cast<String, dynamic>() : const {'status': 'error'};
}

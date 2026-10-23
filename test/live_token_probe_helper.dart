import 'dart:convert';

import 'package:http/http.dart' as http;

Future<String> requestLiveProbeToken({
  required String apiKey,
  required String model,
}) async {
  final now = DateTime.now().toUtc();
  final response = await http.post(
    Uri.parse('https://generativelanguage.googleapis.com/v1beta/auth_tokens'),
    headers: {
      'content-type': 'application/json',
      'x-goog-api-key': apiKey,
    },
    body: jsonEncode({
      'uses': 1,
      'expireTime': now.add(const Duration(minutes: 30)).toIso8601String(),
      'newSessionExpireTime':
          now.add(const Duration(minutes: 1)).toIso8601String(),
      // The REST shape the live-session lambda uses (infra/lambda/
      // live-session/core.mjs): the setup message plus a field mask, not the
      // SDK's liveConnectConstraints.
      'fieldMask': 'model,generationConfig.responseModalities',
      'bidiGenerateContentSetup': {
        'model': 'models/$model',
        'generationConfig': {
          'responseModalities': ['AUDIO'],
        },
      },
    }),
  );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('Could not provision a temporary live token');
  }
  final decoded = jsonDecode(response.body);
  final token = decoded is Map<String, dynamic> ? decoded['name'] : null;
  if (token is! String || token.isEmpty) {
    throw const FormatException('Gemini returned no temporary live token');
  }
  return token;
}

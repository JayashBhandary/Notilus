import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'sse.dart';

/// Google Gemini API — SSE streaming over `models/{model}:streamGenerateContent`.
class GeminiClient extends LlmClient {
  GeminiClient({required this.apiKey});

  final String apiKey;

  static const _base = 'https://generativelanguage.googleapis.com/v1beta';

  Map<String, String> get _headers => {'x-goog-api-key': apiKey};

  @override
  Future<List<String>> listModels() async {
    final res = await http
        .get(Uri.parse('$_base/models?pageSize=200'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw LlmException(
          'listModels HTTP ${res.statusCode}: ${extractApiError(res.body)}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = <String>[];
    for (final m in (body['models'] as List? ?? [])) {
      final map = m as Map<String, dynamic>;
      final methods =
          (map['supportedGenerationMethods'] as List? ?? []).cast<String>();
      if (!methods.contains('generateContent')) continue;
      final name = map['name'] as String? ?? '';
      models.add(name.startsWith('models/') ? name.substring(7) : name);
    }
    return models;
  }

  @override
  Stream<String> chat({
    required String model,
    required List<LlmChatTurn> messages,
    double? temperature,
    http.Client? client,
  }) async* {
    final ownsClient = client == null;
    final c = client ?? http.Client();
    try {
      final system = messages
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n\n');
      final contents = [
        for (final m in messages)
          if (m.role != 'system')
            {
              'role': m.role == 'assistant' ? 'model' : 'user',
              'parts': [
                if (m.content.isNotEmpty) {'text': m.content},
                for (final img in m.images ?? const <LlmImage>[])
                  {
                    'inline_data': {
                      'mime_type': img.mimeType,
                      'data': img.base64,
                    },
                  },
              ],
            },
      ];

      final streamed = await sendJsonStream(
        client: c,
        uri: Uri.parse('$_base/models/$model:streamGenerateContent?alt=sse'),
        headers: _headers,
        body: {
          if (system.isNotEmpty)
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
          'contents': contents,
          if (temperature != null)
            'generationConfig': {'temperature': temperature},
        },
      );

      await for (final data in sseDataLines(streamed.stream)) {
        Map<String, dynamic> obj;
        try {
          obj = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final err = obj['error'];
        if (err is Map && err['message'] is String) {
          throw LlmException(err['message'] as String);
        }
        final candidates = obj['candidates'];
        if (candidates is! List || candidates.isEmpty) continue;
        final content = (candidates.first as Map)['content'];
        if (content is! Map) continue;
        final parts = content['parts'];
        if (parts is! List) continue;
        for (final part in parts) {
          if (part is Map && part['text'] is String) {
            yield part['text'] as String;
          }
        }
      }
    } finally {
      if (ownsClient) c.close();
    }
  }
}

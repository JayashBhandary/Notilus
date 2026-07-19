import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'sse.dart';

/// Anthropic Messages API — SSE streaming over `/v1/messages`.
class AnthropicClient extends LlmClient {
  AnthropicClient({required this.apiKey});

  final String apiKey;

  static const _base = 'https://api.anthropic.com/v1';
  static const _version = '2023-06-01';

  Map<String, String> get _headers => {
        'x-api-key': apiKey,
        'anthropic-version': _version,
      };

  @override
  Future<List<String>> listModels() async {
    final res = await http
        .get(Uri.parse('$_base/models?limit=100'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw LlmException(
          'listModels HTTP ${res.statusCode}: ${extractApiError(res.body)}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['data'] as List? ?? [])
        .map((m) => (m as Map<String, dynamic>)['id'] as String)
        .toList();
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
      // Anthropic takes system text as a top-level param, not a message.
      final system = messages
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n\n');
      final turns = [
        for (final m in messages)
          if (m.role != 'system')
            {
              'role': m.role,
              'content': [
                for (final img in m.images ?? const <LlmImage>[])
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': img.mimeType,
                      'data': img.base64,
                    },
                  },
                if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
              ],
            },
      ];

      final streamed = await sendJsonStream(
        client: c,
        uri: Uri.parse('$_base/messages'),
        headers: _headers,
        body: {
          'model': model,
          'max_tokens': 4096,
          'stream': true,
          if (system.isNotEmpty) 'system': system,
          // Anthropic only accepts 0..1.
          if (temperature != null) 'temperature': temperature.clamp(0.0, 1.0),
          'messages': turns,
        },
      );

      await for (final data in sseDataLines(streamed.stream)) {
        Map<String, dynamic> obj;
        try {
          obj = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        switch (obj['type']) {
          case 'content_block_delta':
            final delta = obj['delta'];
            if (delta is Map && delta['text'] is String) {
              yield delta['text'] as String;
            }
            break;
          case 'error':
            final err = obj['error'];
            throw LlmException(
              err is Map && err['message'] is String
                  ? err['message'] as String
                  : data,
            );
          case 'message_stop':
            return;
        }
      }
    } finally {
      if (ownsClient) c.close();
    }
  }
}

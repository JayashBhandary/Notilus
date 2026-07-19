import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';
import 'sse.dart';

/// OpenAI Chat Completions API — also serves any OpenAI-compatible server
/// (LM Studio, OpenRouter, Groq, Mistral…) via a custom [baseUrl].
class OpenAIClient extends LlmClient {
  OpenAIClient({required this.apiKey, String? baseUrl})
      : baseUrl = _normaliseBaseUrl(baseUrl);

  final String apiKey;

  /// Includes the version segment, e.g. `https://api.openai.com/v1`.
  final String baseUrl;

  static String _normaliseBaseUrl(String? raw) {
    var b = (raw ?? '').trim();
    if (b.isEmpty) return 'https://api.openai.com/v1';
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://$b';
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Map<String, String> get _headers =>
      {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'};

  // The models endpoint mixes chat models with embeddings/audio/image ones;
  // hide the obvious non-chat entries so pickers stay usable.
  static const _nonChatMarkers = [
    'embedding', 'whisper', 'tts', 'dall-e', 'moderation',
    'davinci', 'babbage', 'audio', 'realtime', 'transcribe', 'image',
  ];

  @override
  Future<List<String>> listModels() async {
    final res = await http
        .get(Uri.parse('$baseUrl/models'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw LlmException(
          'listModels HTTP ${res.statusCode}: ${extractApiError(res.body)}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (body['data'] as List? ?? [])
        .map((m) => (m as Map<String, dynamic>)['id'] as String)
        .where((id) => !_nonChatMarkers.any(id.contains))
        .toList()
      ..sort();
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
      final msgs = [
        for (final m in messages)
          {
            'role': m.role,
            // Plain string unless the turn carries images, which need the
            // structured content-parts form.
            'content': (m.images == null || m.images!.isEmpty)
                ? m.content
                : [
                    if (m.content.isNotEmpty)
                      {'type': 'text', 'text': m.content},
                    for (final img in m.images!)
                      {
                        'type': 'image_url',
                        'image_url': {
                          'url': 'data:${img.mimeType};base64,${img.base64}',
                        },
                      },
                  ],
          },
      ];

      final streamed = await sendJsonStream(
        client: c,
        uri: Uri.parse('$baseUrl/chat/completions'),
        headers: _headers,
        body: {
          'model': model,
          'stream': true,
          'messages': msgs,
          if (temperature != null) 'temperature': temperature,
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
        final choices = obj['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        if (delta is Map && delta['content'] is String) {
          final chunk = delta['content'] as String;
          if (chunk.isNotEmpty) yield chunk;
        }
      }
    } finally {
      if (ownsClient) c.close();
    }
  }
}

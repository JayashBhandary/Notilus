import 'dart:convert';

import 'package:http/http.dart' as http;

/// Which LLM backend a request goes to.
enum LlmProviderKind { ollama, anthropic, gemini, openai, openaiCompat }

extension LlmProviderKindInfo on LlmProviderKind {
  String get id {
    switch (this) {
      case LlmProviderKind.ollama:
        return 'ollama';
      case LlmProviderKind.anthropic:
        return 'anthropic';
      case LlmProviderKind.gemini:
        return 'gemini';
      case LlmProviderKind.openai:
        return 'openai';
      case LlmProviderKind.openaiCompat:
        return 'openai_compat';
    }
  }

  String get label {
    switch (this) {
      case LlmProviderKind.ollama:
        return 'Ollama';
      case LlmProviderKind.anthropic:
        return 'Claude';
      case LlmProviderKind.gemini:
        return 'Gemini';
      case LlmProviderKind.openai:
        return 'OpenAI';
      case LlmProviderKind.openaiCompat:
        return 'Custom';
    }
  }

  /// Cloud providers can't work without a key. Ollama is keyless; a custom
  /// OpenAI-compatible server (LM Studio, OpenRouter…) may or may not need one.
  bool get requiresApiKey =>
      this == LlmProviderKind.anthropic ||
      this == LlmProviderKind.gemini ||
      this == LlmProviderKind.openai;

  bool get supportsApiKey => this != LlmProviderKind.ollama;

  static LlmProviderKind fromId(String id) {
    for (final k in LlmProviderKind.values) {
      if (k.id == id) return k;
    }
    return LlmProviderKind.ollama;
  }
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => 'LlmException: $message';
}

/// An image attached to a chat turn — only honoured by vision-capable models.
class LlmImage {
  LlmImage({required this.base64, required this.mimeType});
  final String base64;
  final String mimeType; // e.g. image/png
}

class LlmChatTurn {
  LlmChatTurn({
    required this.role,
    required this.content,
    this.images,
  });
  final String role; // 'system' | 'user' | 'assistant'
  final String content;
  final List<LlmImage>? images;
}

/// Provider-agnostic streaming LLM client — one implementation per backend.
abstract class LlmClient {
  /// Model ids available on this provider (network call).
  Future<List<String>> listModels();

  /// Streams response text for a full conversation.
  Stream<String> chat({
    required String model,
    required List<LlmChatTurn> messages,
    double? temperature,
    http.Client? client,
  });

  /// Single-prompt convenience used by workflows and system insight.
  Stream<String> generate({
    required String model,
    required String prompt,
    double? temperature,
    http.Client? client,
  }) {
    return chat(
      model: model,
      messages: [LlmChatTurn(role: 'user', content: prompt)],
      temperature: temperature,
      client: client,
    );
  }

  Future<bool> ping() async {
    try {
      await listModels();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Pulls the human-readable message out of a provider error body
/// (`{"error": {"message": …}}` for OpenAI/Gemini/Anthropic alike).
String extractApiError(String body) {
  try {
    final obj = jsonDecode(body);
    if (obj is Map) {
      final err = obj['error'];
      if (err is Map && err['message'] is String) return err['message'] as String;
      if (err is String) return err;
    }
  } catch (_) {}
  return body;
}

/// POSTs [body] as JSON and returns the streamed response, converting
/// timeouts and non-200 statuses into [LlmException]s.
Future<http.StreamedResponse> sendJsonStream({
  required http.Client client,
  required Uri uri,
  required Map<String, dynamic> body,
  Map<String, String> headers = const {},
  String? timeoutMessage,
}) async {
  final req = http.Request('POST', uri);
  req.headers['Content-Type'] = 'application/json';
  req.headers.addAll(headers);
  req.body = jsonEncode(body);

  final streamed = await client.send(req).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw LlmException(
          timeoutMessage ?? 'Connection to ${uri.host} timed out.',
        ),
      );

  if (streamed.statusCode != 200) {
    final errBody = await streamed.stream.bytesToString();
    throw LlmException(
      'HTTP ${streamed.statusCode} from ${uri.path}: '
      '${errBody.isEmpty ? '(empty body)' : extractApiError(errBody)}',
    );
  }
  return streamed;
}

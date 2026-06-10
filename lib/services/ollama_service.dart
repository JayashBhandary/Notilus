import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class OllamaException implements Exception {
  OllamaException(this.message);
  final String message;
  @override
  String toString() => 'OllamaException: $message';
}

class OllamaChatTurn {
  OllamaChatTurn({
    required this.role,
    required this.content,
    this.images,
  });
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  /// Base64-encoded image bytes — only honoured by vision-capable models.
  final List<String>? images;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (images != null && images!.isNotEmpty) 'images': images,
      };
}

class OllamaService {
  OllamaService(String host) : host = _normaliseHost(host);

  String host;

  static String _normaliseHost(String raw) {
    var h = raw.trim();
    if (h.isEmpty) return 'http://localhost:11434';
    if (!h.startsWith('http://') && !h.startsWith('https://')) {
      h = 'http://$h';
    }
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }

  Uri _uri(String path) => Uri.parse('$host$path');

  Future<List<String>> listModels() async {
    final res = await http
        .get(_uri('/api/tags'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw OllamaException('listModels HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (body['models'] as List? ?? [])
        .map((m) => (m as Map<String, dynamic>)['name'] as String)
        .toList();
    return models;
  }

  Future<bool> ping() async {
    try {
      await listModels();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Streams tokens from `/api/generate` (single prompt, no history).
  Stream<String> generate({
    required String model,
    required String prompt,
    double? temperature,
    http.Client? client,
  }) {
    return _streamRequest(
      path: '/api/generate',
      body: {
        'model': model,
        'prompt': prompt,
        'stream': true,
        if (temperature != null) 'options': {'temperature': temperature},
      },
      client: client,
    );
  }

  /// Streams tokens from `/api/chat` with full conversation history.
  Stream<String> chat({
    required String model,
    required List<OllamaChatTurn> messages,
    double? temperature,
    http.Client? client,
  }) {
    return _streamRequest(
      path: '/api/chat',
      body: {
        'model': model,
        'messages': messages.map((m) => m.toJson()).toList(),
        'stream': true,
        if (temperature != null) 'options': {'temperature': temperature},
      },
      client: client,
    );
  }

  Stream<String> _streamRequest({
    required String path,
    required Map<String, dynamic> body,
    http.Client? client,
  }) async* {
    final ownsClient = client == null;
    final c = client ?? http.Client();
    try {
      final req = http.Request('POST', _uri(path));
      req.headers['Content-Type'] = 'application/json';
      req.headers['Accept'] = 'application/x-ndjson';
      req.body = jsonEncode(body);

      final streamed = await c.send(req).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw OllamaException(
          'Connection to $host timed out. Is Ollama running?',
        ),
      );

      if (streamed.statusCode != 200) {
        final errBody = await streamed.stream.bytesToString();
        throw OllamaException(
          'HTTP ${streamed.statusCode} from $path: ${errBody.isEmpty ? '(empty body)' : errBody}',
        );
      }

      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        Map<String, dynamic> obj;
        try {
          obj = jsonDecode(trimmed) as Map<String, dynamic>;
        } catch (_) {
          continue; // ignore malformed line
        }

        // Server-side error reported in the stream.
        final err = obj['error'];
        if (err is String && err.isNotEmpty) {
          throw OllamaException(err);
        }

        // /api/generate → "response"; /api/chat → "message.content".
        String? chunk;
        final resp = obj['response'];
        if (resp is String && resp.isNotEmpty) {
          chunk = resp;
        } else {
          final msg = obj['message'];
          if (msg is Map) {
            final content = msg['content'];
            if (content is String && content.isNotEmpty) chunk = content;
          }
        }
        if (chunk != null) yield chunk;

        if (obj['done'] == true) break;
      }
    } finally {
      if (ownsClient) c.close();
    }
  }
}

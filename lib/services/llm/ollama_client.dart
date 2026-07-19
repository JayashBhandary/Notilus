import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';

/// Local Ollama server — NDJSON streaming over `/api/chat` / `/api/generate`.
class OllamaClient extends LlmClient {
  OllamaClient(String host) : host = _normaliseHost(host);

  final String host;

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

  @override
  Future<List<String>> listModels() async {
    final res = await http
        .get(_uri('/api/tags'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw LlmException('listModels HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (body['models'] as List? ?? [])
        .map((m) => (m as Map<String, dynamic>)['name'] as String)
        .toList();
    return models;
  }

  @override
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

  @override
  Stream<String> chat({
    required String model,
    required List<LlmChatTurn> messages,
    double? temperature,
    http.Client? client,
  }) {
    return _streamRequest(
      path: '/api/chat',
      body: {
        'model': model,
        'messages': [
          for (final m in messages)
            {
              'role': m.role,
              'content': m.content,
              if (m.images != null && m.images!.isNotEmpty)
                'images': [for (final img in m.images!) img.base64],
            },
        ],
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
      final streamed = await sendJsonStream(
        client: c,
        uri: _uri(path),
        headers: const {'Accept': 'application/x-ndjson'},
        body: body,
        timeoutMessage: 'Connection to $host timed out. Is Ollama running?',
      );

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
          throw LlmException(err);
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

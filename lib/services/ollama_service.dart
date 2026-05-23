import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class OllamaException implements Exception {
  OllamaException(this.message);
  final String message;
  @override
  String toString() => 'OllamaException: $message';
}

class OllamaService {
  OllamaService(this.host);

  String host;

  Uri _uri(String path) {
    final base = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
    return Uri.parse('$base$path');
  }

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

  /// Streams response tokens as they arrive from /api/generate.
  Stream<String> generate({
    required String model,
    required String prompt,
    double? temperature,
  }) async* {
    final request = http.Request('POST', _uri('/api/generate'));
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model': model,
      'prompt': prompt,
      'stream': true,
      if (temperature != null) 'options': {'temperature': temperature},
    });

    final streamed = await request.send();
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw OllamaException('generate HTTP ${streamed.statusCode}: $body');
    }

    final lineStream = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      if (line.trim().isEmpty) continue;
      try {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        final chunk = obj['response'] as String?;
        if (chunk != null && chunk.isNotEmpty) yield chunk;
        if (obj['done'] == true) break;
      } catch (_) {
        // ignore malformed line
      }
    }
  }
}

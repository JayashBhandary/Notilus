import 'dart:convert';

/// Extracts `data:` payloads from a server-sent-events byte stream.
/// Ends when the stream closes or an OpenAI-style `[DONE]` sentinel arrives.
Stream<String> sseDataLines(Stream<List<int>> bytes) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty) continue;
    if (data == '[DONE]') return;
    yield data;
  }
}

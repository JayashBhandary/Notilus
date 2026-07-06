/// One decoded Server-Sent Event. For Firebase RTDB streams, [event] is one of
/// `put` / `patch` / `keep-alive` / `cancel` / `auth_revoked`, and [data] is the
/// raw (usually JSON) payload string.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;
}

/// Decodes a stream of already-split SSE lines into [SseEvent]s. Events are
/// separated by blank lines; `data:` fields accumulate (newline-joined) and a
/// leading space after the colon is stripped, per the SSE spec. `:` comment
/// lines and unknown fields (`id`, `retry`) are ignored.
Stream<SseEvent> decodeSse(Stream<String> lines) async* {
  String? event;
  final data = StringBuffer();
  var hasData = false;

  await for (final line in lines) {
    if (line.isEmpty) {
      if (hasData || event != null) {
        yield SseEvent(event ?? 'message', data.toString());
      }
      event = null;
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue; // comment
    final idx = line.indexOf(':');
    final field = idx < 0 ? line : line.substring(0, idx);
    var value = idx < 0 ? '' : line.substring(idx + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
        break;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
        break;
      default:
        break; // id / retry / unknown
    }
  }
  if (hasData || event != null) {
    yield SseEvent(event ?? 'message', data.toString());
  }
}

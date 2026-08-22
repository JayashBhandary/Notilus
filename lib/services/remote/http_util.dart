import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_file_system.dart';

/// Thin wrapper over `dart:io`'s HttpClient for the remote providers.
///
/// `package:http` is used elsewhere in the app for JSON-sized requests, but a
/// file manager moves whole files: uploads have to stream from disk with real
/// backpressure, which `HttpClientRequest.addStream` gives and
/// `http.StreamedRequest` does not — its sink buffers whatever it is fed, so a
/// multi-gigabyte upload would first become a multi-gigabyte allocation.
class RemoteHttp {
  RemoteHttp() {
    _client
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'Notilus';
  }

  final HttpClient _client = HttpClient();

  Future<HttpClientResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  }) async {
    final HttpClientRequest request;
    try {
      request = await _client.openUrl(method, uri);
    } on SocketException catch (e) {
      throw RemoteException('Can\'t reach ${uri.host}: ${e.osError?.message ?? e.message}');
    } on HandshakeException {
      throw RemoteException('TLS handshake with ${uri.host} failed.');
    }
    // A redirect replays the request without the signature that was computed
    // for the original URL, so it would fail authentication in a way that
    // reads like bad credentials. Providers surface the Location instead.
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (contentLength != null) request.contentLength = contentLength;
    if (body != null) {
      await request.addStream(body);
    }
    return request.close();
  }

  /// Sends a request whose response body is small enough to hold in memory,
  /// and hands back the decoded text along with the status.
  Future<({int status, String body, HttpHeaders headers})> sendText(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  }) async {
    final response = await send(
      method,
      uri,
      headers: headers,
      body: body,
      contentLength: contentLength,
    );
    final text = await readText(response);
    return (status: response.statusCode, body: text, headers: response.headers);
  }

  static Future<String> readText(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  static Future<Map<String, dynamic>> readJson(
    HttpClientResponse response,
  ) async {
    final text = await readText(response);
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {'value': decoded};
  }

  void close() => _client.close(force: true);
}

/// Percent-encodes one path segment per RFC 3986 — the unreserved set stays
/// literal, everything else becomes %XX. `Uri.encodeComponent` leaves `!*'()`
/// alone, which S3's signature calculation does not, so signing can't use it.
String uriEncodeComponent(String input) {
  const unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~';
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final char = String.fromCharCode(byte);
    if (unreserved.contains(char)) {
      out.write(char);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Encodes a whole path, keeping `/` as a separator.
String uriEncodePath(String path) =>
    path.split('/').map(uriEncodeComponent).join('/');

/// Counts bytes as they flow past, for progress reporting.
Stream<List<int>> countingStream(
  Stream<List<int>> source,
  void Function(int delta) onBytes,
) async* {
  await for (final chunk in source) {
    onBytes(chunk.length);
    yield chunk;
  }
}

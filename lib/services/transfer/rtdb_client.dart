import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/transfer_config.dart';
import 'firebase_auth_client.dart';

class TransferRtdbException implements Exception {
  TransferRtdbException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'TransferRtdbException($statusCode): $body';
}

/// Thin REST client for Firebase Realtime Database. Every request carries the
/// current auth id token so the security rules can scope by `auth.uid`.
/// Paths are DB paths WITHOUT the `.json` suffix, e.g. `users/$uid/profile`.
class RtdbClient {
  RtdbClient(this._auth, {http.Client? client})
      : _http = client ?? http.Client();

  final FirebaseAuthClient _auth;
  final http.Client _http;

  Future<Uri> _uri(String path) async {
    final token = await _auth.validToken();
    return Uri.parse('${TransferConfig.rtdbUrl}/$path.json?auth=$token');
  }

  Future<dynamic> get(String path) async {
    final r = await _http.get(await _uri(path));
    _check(r);
    return jsonDecode(r.body);
  }

  Future<void> put(String path, Object? data) async {
    final r = await _http.put(await _uri(path), body: jsonEncode(data));
    _check(r);
  }

  Future<void> patch(String path, Map<String, Object?> data) async {
    final r = await _http.patch(await _uri(path), body: jsonEncode(data));
    _check(r);
  }

  /// POST = RTDB push; returns the generated child key.
  Future<String> push(String path, Object? data) async {
    final r = await _http.post(await _uri(path), body: jsonEncode(data));
    _check(r);
    return (jsonDecode(r.body) as Map)['name'] as String;
  }

  Future<void> delete(String path) async {
    final r = await _http.delete(await _uri(path));
    _check(r);
  }

  void close() => _http.close();

  void _check(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw TransferRtdbException(r.statusCode, r.body);
    }
  }
}

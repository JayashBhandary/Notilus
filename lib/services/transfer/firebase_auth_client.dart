import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/transfer_config.dart';
import 'kv_store.dart';

class TransferAuthException implements Exception {
  TransferAuthException(this.message);
  final String message;
  @override
  String toString() => 'TransferAuthException: $message';
}

/// Firebase anonymous authentication over the Identity Toolkit REST API
/// (no FlutterFire plugin, so it works on macOS/Windows/Linux).
///
/// Signs up anonymously exactly once, then persists the refresh token and
/// reuses it on later launches — so the uid (which becomes our `deviceId`)
/// stays stable. [validToken] transparently refreshes the id token before it
/// expires.
class FirebaseAuthClient {
  FirebaseAuthClient(this._store, {http.Client? client})
      : _http = client ?? http.Client();

  final KvStore _store;
  final http.Client _http;

  static const _kRefresh = 'transfer.auth.refreshToken';
  static const _kUid = 'transfer.auth.uid';

  String? _idToken;
  String? _uid;
  DateTime _expiry = DateTime.fromMillisecondsSinceEpoch(0);

  String? get uid => _uid;

  /// Ensures we have a valid session (refresh if we have a token, else sign up).
  Future<void> init() async {
    final refresh = _store.getString(_kRefresh);
    if (refresh != null && refresh.isNotEmpty) {
      await _refresh(refresh);
    } else {
      await _signUpAnonymously();
    }
  }

  /// Returns a currently-valid id token, refreshing ~1 min before expiry.
  Future<String> validToken() async {
    final soon = DateTime.now().add(const Duration(seconds: 60));
    if (_idToken == null || soon.isAfter(_expiry)) {
      final refresh = _store.getString(_kRefresh);
      if (refresh != null && refresh.isNotEmpty) {
        await _refresh(refresh);
      } else {
        await _signUpAnonymously();
      }
    }
    return _idToken!;
  }

  void close() => _http.close();

  Future<void> _signUpAnonymously() async {
    final r = await _http.post(
      Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${TransferConfig.apiKey}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'returnSecureToken': true}),
    );
    final d = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) {
      throw TransferAuthException(
          (d['error']?['message'] ?? 'anonymous sign-in failed').toString());
    }
    _idToken = d['idToken'] as String;
    _uid = d['localId'] as String;
    _expiry = DateTime.now()
        .add(Duration(seconds: int.tryParse('${d['expiresIn']}') ?? 3600));
    await _store.setString(_kRefresh, d['refreshToken'] as String);
    await _store.setString(_kUid, _uid!);
  }

  Future<void> _refresh(String refreshToken) async {
    final r = await _http.post(
      Uri.parse(
          'https://securetoken.googleapis.com/v1/token?key=${TransferConfig.apiKey}'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
    );
    if (r.statusCode != 200) {
      // Refresh token no longer valid — fall back to a fresh anonymous account.
      await _store.remove(_kRefresh);
      await _signUpAnonymously();
      return;
    }
    final d = jsonDecode(r.body) as Map<String, dynamic>;
    _idToken = d['id_token'] as String;
    _uid = d['user_id'] as String;
    _expiry = DateTime.now()
        .add(Duration(seconds: int.tryParse('${d['expires_in']}') ?? 3600));
    await _store.setString(_kRefresh, d['refresh_token'] as String);
    await _store.setString(_kUid, _uid!);
  }
}

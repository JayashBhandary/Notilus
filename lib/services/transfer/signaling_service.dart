import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/transfer_config.dart';
import '../../models/transfer/inbox_message.dart';
import 'firebase_auth_client.dart';
import 'identity_service.dart';
import 'rtdb_client.dart';
import 'sse.dart';

/// Coordinates all signaling over Firebase RTDB: signs in, publishes our
/// profile, streams our inbox (via SSE) as [messages], sends messages to
/// peers, and heartbeats presence. No file bytes ever pass through here — this
/// is only the tiny meeting-point channel.
class SignalingService {
  SignalingService({
    required this.auth,
    required this.rtdb,
    required this.identity,
    http.Client? sseClient,
  }) : _sseClient = sseClient ?? http.Client();

  final FirebaseAuthClient auth;
  final RtdbClient rtdb;
  final IdentityService identity;
  final http.Client _sseClient;

  static const _heartbeatEvery = Duration(seconds: 20);
  static const onlineWindow = Duration(seconds: 70);

  final _messages = StreamController<InboxMessage>.broadcast();
  Stream<InboxMessage> get messages => _messages.stream;

  String? _uid;
  String? get uid => _uid;

  Timer? _heartbeat;
  StreamSubscription<SseEvent>? _sseSub;
  bool _running = false;

  /// Signs in, publishes profile, opens the inbox stream, starts heartbeat.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await auth.init();
    _uid = auth.uid;
    await identity.setDeviceId(_uid!);
    await publishProfile();
    await _connectInbox();
    _heartbeat = Timer.periodic(_heartbeatEvery, (_) => _beat());
  }

  /// (Re)publishes our profile — call after the display name changes.
  Future<void> publishProfile() => rtdb.put('users/$_uid/profile', {
        'name': identity.displayName,
        'publicKey': identity.publicKeyBase64,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });

  Future<void> _beat() async {
    try {
      await rtdb.patch(
          'users/$_uid/profile', {'lastSeen': DateTime.now().millisecondsSinceEpoch});
    } catch (_) {
      // Non-fatal; next tick retries.
    }
  }

  /// Drops [message] into [toDeviceId]'s inbox. Returns the RTDB push id.
  Future<String> send(String toDeviceId, InboxMessage message) =>
      rtdb.push('users/$toDeviceId/inbox', message.toMap());

  /// Removes a handled message from our own inbox.
  Future<void> deleteInboxMessage(String id) =>
      rtdb.delete('users/$_uid/inbox/$id');

  /// Removes a message we pushed into a peer's inbox (e.g. an unanswered
  /// request), so it doesn't orphan when the peer never consumed it.
  Future<void> deletePeerMessage(String toDeviceId, String id) =>
      rtdb.delete('users/$toDeviceId/inbox/$id');

  /// Reads a peer's profile (name + publicKey), or null if absent.
  Future<Map<String, dynamic>?> fetchProfile(String deviceId) async {
    try {
      final p = await rtdb.get('users/$deviceId/profile');
      return p is Map ? p.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// True if the peer's `lastSeen` heartbeat is recent.
  Future<bool> isOnline(String deviceId) async {
    final p = await fetchProfile(deviceId);
    final last = p?['lastSeen'];
    final ms = last is int ? last : int.tryParse('$last') ?? 0;
    return DateTime.now().millisecondsSinceEpoch - ms < onlineWindow.inMilliseconds;
  }

  Future<void> _connectInbox() async {
    try {
      final token = await auth.validToken();
      final req = http.Request(
        'GET',
        Uri.parse('${TransferConfig.rtdbUrl}/users/$_uid/inbox.json?auth=$token'),
      );
      req.headers['Accept'] = 'text/event-stream';
      req.headers['Cache-Control'] = 'no-cache';
      final resp = await _sseClient.send(req);
      final lines =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      _sseSub = decodeSse(lines).listen(
        _onSse,
        onError: (_) => _reconnect(),
        onDone: _reconnect,
        cancelOnError: false,
      );
    } catch (_) {
      _reconnect();
    }
  }

  void _onSse(SseEvent e) {
    switch (e.event) {
      case 'keep-alive':
        return;
      case 'auth_revoked':
      case 'cancel':
        _reconnect();
        return;
      case 'put':
      case 'patch':
        break;
      default:
        return;
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(e.data);
      if (decoded is! Map) return;
      body = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }

    final path = (body['path'] ?? '') as String;
    final data = body['data'];

    if (path == '/') {
      // Initial snapshot: whole inbox as { pushId: message } (or null if empty).
      if (data is Map) {
        data.forEach((k, v) {
          if (v is Map) _emit(k as String, v.cast<String, dynamic>());
        });
      }
      return;
    }

    // Live change at '/<pushId>'. Ignore deeper field patches and deletions.
    final seg = path.startsWith('/') ? path.substring(1) : path;
    if (seg.isEmpty || seg.contains('/')) return;
    if (data is Map) _emit(seg, data.cast<String, dynamic>());
  }

  void _emit(String id, Map<String, dynamic> m) {
    if (m['type'] == null) return;
    _messages.add(InboxMessage.fromMap(id, m));
  }

  void _reconnect() {
    if (!_running) return;
    _sseSub?.cancel();
    _sseSub = null;
    Future.delayed(const Duration(seconds: 2), () {
      if (_running) _connectInbox();
    });
  }

  Future<void> stop() async {
    _running = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient.close();
    await _messages.close();
  }
}

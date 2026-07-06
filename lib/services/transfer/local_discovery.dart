import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'identity_service.dart';

/// A peer found on the local network: where to open the TCP transfer socket.
class LanPeer {
  const LanPeer(this.address, this.port);
  final InternetAddress address;
  final int port;
}

/// In-app LAN peer discovery over UDP multicast — no Firebase, no native plugin.
///
/// Each running instance answers "who has deviceId X?" queries for its own id
/// with a **signed** reply carrying its TCP transfer port. [locate] broadcasts a
/// query and returns the peer's address+port only if a reply verifies against
/// the saved contact's public key (so a LAN attacker can't impersonate a
/// contact), binding a per-query nonce to defeat replay.
class LocalDiscovery {
  LocalDiscovery(this._identity);

  final IdentityService _identity;

  static final InternetAddress _group = InternetAddress('239.255.7.24');
  static const int _port = 50327;
  static const String _prefix = 'notilus-lan-v1';

  RawDatagramSocket? _socket;
  final Random _rng = Random.secure();
  int _tcpPort = 0;
  final Map<String, _Pending> _pending = {}; // nonce → awaiting locate()

  /// The TCP port our [LocalTransferServer] listens on; advertised in replies.
  set tcpPort(int port) => _tcpPort = port;

  bool get isRunning => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await _bind();
    if (socket == null) return;
    try {
      socket.joinMulticast(_group);
    } catch (e) {
      debugPrint('LocalDiscovery multicast join failed: $e');
    }
    socket.listen(_onEvent);
    _socket = socket;
  }

  Future<RawDatagramSocket?> _bind() async {
    // reusePort lets two instances share the port on one host (handy for
    // testing); some platforms reject it, so fall back to reuseAddress only.
    try {
      return await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port,
          reuseAddress: true, reusePort: true);
    } catch (_) {}
    try {
      return await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port,
          reuseAddress: true);
    } catch (e) {
      debugPrint('LocalDiscovery bind failed: $e');
      return null;
    }
  }

  /// Broadcasts a query for [deviceId] and returns the peer if a reply verifies
  /// against [publicKey] within [timeout]; otherwise null.
  Future<LanPeer?> locate(
    String deviceId,
    String publicKey, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final socket = _socket;
    if (socket == null) return null;
    final nonce =
        base64Url.encode(List<int>.generate(12, (_) => _rng.nextInt(256)));
    final pending = _Pending(deviceId, publicKey);
    _pending[nonce] = pending;
    try {
      socket.send(
        utf8.encode(jsonEncode({'t': 'q', 'id': deviceId, 'n': nonce})),
        _group,
        _port,
      );
    } catch (_) {
      _pending.remove(nonce);
      return null;
    }
    try {
      return await pending.completer.future
          .timeout(timeout, onTimeout: () => null);
    } finally {
      _pending.remove(nonce);
    }
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.complete(null);
    }
    _pending.clear();
  }

  // ── wire handling ──────────────────────────────────────────────────────
  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(utf8.decode(dg.data));
      if (decoded is! Map) return;
      msg = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (msg['t']) {
      case 'q':
        unawaited(_handleQuery(msg, dg.address));
        break;
      case 'r':
        unawaited(_handleReply(msg, dg.address));
        break;
    }
  }

  Future<void> _handleQuery(Map<String, dynamic> msg, InternetAddress from) async {
    final myId = _identity.deviceId;
    final target = msg['id'];
    final nonce = msg['n'];
    if (myId == null || target != myId || nonce is! String || _tcpPort == 0) {
      return;
    }
    final sig =
        await _identity.sign(utf8.encode(_signBase(myId, _tcpPort, nonce)));
    final reply = jsonEncode({
      't': 'r',
      'id': myId,
      'port': _tcpPort,
      'n': nonce,
      'sig': base64.encode(sig),
    });
    try {
      _socket?.send(utf8.encode(reply), from, _port);
    } catch (_) {}
  }

  Future<void> _handleReply(Map<String, dynamic> msg, InternetAddress from) async {
    final nonce = msg['n'];
    if (nonce is! String) return;
    final pending = _pending[nonce];
    if (pending == null || pending.completer.isCompleted) return;
    final id = msg['id'];
    final port = msg['port'];
    final sig = msg['sig'];
    if (id != pending.deviceId || port is! int || sig is! String) return;
    final ok = await _identity.verify(
      utf8.encode(_signBase(pending.deviceId, port, nonce)),
      base64.decode(sig),
      pending.publicKey,
    );
    if (!ok || pending.completer.isCompleted) return;
    pending.completer.complete(LanPeer(from, port));
  }

  static String _signBase(String deviceId, int port, String nonce) =>
      '$_prefix|$deviceId|$port|$nonce';
}

class _Pending {
  _Pending(this.deviceId, this.publicKey);
  final String deviceId;
  final String publicKey;
  final Completer<LanPeer?> completer = Completer<LanPeer?>();
}

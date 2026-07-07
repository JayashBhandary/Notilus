import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../utils/device_code.dart';
import 'identity_service.dart';

/// A peer found on the local network: where to open the TCP transfer socket.
class LanPeer {
  const LanPeer(this.address, this.port);
  final InternetAddress address;
  final int port;
}

/// A peer's identity resolved from just their machine code over the LAN, used to
/// add them as a contact. Self-certifying: the caller only trusts it once the
/// [publicKey] re-derives the requested code.
class LanProfile {
  const LanProfile(
      {required this.name, required this.publicKey, required this.uid});
  final String name;
  final String publicKey; // base64 Ed25519
  final String uid; // Firebase uid ('' if not signed in) — online routing
}

/// In-app LAN peer discovery over UDP multicast — no Firebase, no native plugin.
///
/// Each running instance answers "who has machine code X?" queries for its own
/// code with a **signed** reply carrying its TCP transfer port. [locate]
/// broadcasts a query and returns the peer's address+port only if a reply
/// verifies against the saved contact's public key (so a LAN attacker can't
/// impersonate a contact), binding a per-query nonce to defeat replay. Uses the
/// machine code, not the Firebase uid, so discovery works with no internet.
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
  final Map<String, _ProfilePending> _profilePending = {}; // nonce → resolve()

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

  /// Broadcasts a query for machine [code] and returns the peer if a reply
  /// verifies against [publicKey] within [timeout]; otherwise null.
  Future<LanPeer?> locate(
    String code,
    String publicKey, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final socket = _socket;
    if (socket == null) return null;
    final nonce =
        base64Url.encode(List<int>.generate(12, (_) => _rng.nextInt(256)));
    final pending = _Pending(code, publicKey);
    _pending[nonce] = pending;
    try {
      socket.send(
        utf8.encode(jsonEncode({'t': 'q', 'id': code, 'n': nonce})),
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

  /// Broadcasts a request to resolve machine [code] into a full identity, so a
  /// peer can be added by code alone. Returns the profile only if a reply's
  /// public key re-derives [code] (self-certifying) and its signature verifies;
  /// otherwise null.
  Future<LanProfile?> resolveProfile(
    String code, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = _socket;
    if (socket == null) return null;
    final nonce = _nonce();
    final pending = _ProfilePending(code);
    _profilePending[nonce] = pending;
    try {
      socket.send(
        utf8.encode(jsonEncode({'t': 'pq', 'code': code, 'n': nonce})),
        _group,
        _port,
      );
    } catch (_) {
      _profilePending.remove(nonce);
      return null;
    }
    try {
      return await pending.completer.future
          .timeout(timeout, onTimeout: () => null);
    } finally {
      _profilePending.remove(nonce);
    }
  }

  String _nonce() =>
      base64Url.encode(List<int>.generate(12, (_) => _rng.nextInt(256)));

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) p.completer.complete(null);
    }
    _pending.clear();
    for (final p in _profilePending.values) {
      if (!p.completer.isCompleted) p.completer.complete(null);
    }
    _profilePending.clear();
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
      case 'pq':
        unawaited(_handleProfileQuery(msg, dg.address));
        break;
      case 'pr':
        unawaited(_handleProfileReply(msg));
        break;
    }
  }

  /// Answers a profile query for our own code with a signed identity.
  Future<void> _handleProfileQuery(
      Map<String, dynamic> msg, InternetAddress from) async {
    final myCode = _identity.myCode;
    final nonce = msg['n'];
    if (msg['code'] != myCode || nonce is! String) return;
    final name = _identity.displayName;
    final pk = _identity.publicKeyBase64;
    final uid = _identity.deviceId ?? '';
    final sig = await _identity
        .sign(utf8.encode(_profileSignBase(myCode, pk, uid, name, nonce)));
    final reply = jsonEncode({
      't': 'pr',
      'code': myCode,
      'name': name,
      'pk': pk,
      'uid': uid,
      'n': nonce,
      'sig': base64.encode(sig),
    });
    try {
      _socket?.send(utf8.encode(reply), from, _port);
    } catch (_) {}
  }

  Future<void> _handleProfileReply(Map<String, dynamic> msg) async {
    final nonce = msg['n'];
    if (nonce is! String) return;
    final pending = _profilePending[nonce];
    if (pending == null || pending.completer.isCompleted) return;
    final code = msg['code'];
    final name = msg['name'];
    final pk = msg['pk'];
    final uid = msg['uid'];
    final sig = msg['sig'];
    if (code != pending.code ||
        name is! String ||
        pk is! String ||
        uid is! String ||
        sig is! String) {
      return;
    }
    // Self-certify: only trust a key that actually re-derives the code we asked
    // for, then confirm it signed this exact reply.
    if (deviceCodeFromPublicKey(pk) != pending.code) return;
    final ok = await _identity.verify(
      utf8.encode(_profileSignBase(pending.code, pk, uid, name, nonce)),
      base64.decode(sig),
      pk,
    );
    if (!ok || pending.completer.isCompleted) return;
    pending.completer.complete(LanProfile(name: name, publicKey: pk, uid: uid));
  }

  Future<void> _handleQuery(Map<String, dynamic> msg, InternetAddress from) async {
    final myCode = _identity.myCode;
    final target = msg['id'];
    final nonce = msg['n'];
    if (target != myCode || nonce is! String || _tcpPort == 0) {
      return;
    }
    final sig =
        await _identity.sign(utf8.encode(_signBase(myCode, _tcpPort, nonce)));
    final reply = jsonEncode({
      't': 'r',
      'id': myCode,
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
    if (id != pending.code || port is! int || sig is! String) return;
    final ok = await _identity.verify(
      utf8.encode(_signBase(pending.code, port, nonce)),
      base64.decode(sig),
      pending.publicKey,
    );
    if (!ok || pending.completer.isCompleted) return;
    pending.completer.complete(LanPeer(from, port));
  }

  static String _signBase(String code, int port, String nonce) =>
      '$_prefix|$code|$port|$nonce';

  static String _profileSignBase(
          String code, String pk, String uid, String name, String nonce) =>
      '$_prefix|profile|$code|$pk|$uid|$name|$nonce';
}

class _Pending {
  _Pending(this.code, this.publicKey);
  final String code;
  final String publicKey;
  final Completer<LanPeer?> completer = Completer<LanPeer?>();
}

class _ProfilePending {
  _ProfilePending(this.code);
  final String code;
  final Completer<LanProfile?> completer = Completer<LanProfile?>();
}

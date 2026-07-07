import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../models/transfer/contact.dart';
import '../../utils/device_code.dart';
import 'kv_store.dart';

/// This machine's identity for P2P transfer.
///
/// Holds a persistent Ed25519 signing keypair (so peers can verify our inbox
/// messages), a display name, and the [deviceId] — which is the Firebase
/// anonymous uid. The uid is only known after sign-in, so [deviceId] is
/// populated by the auth layer in Phase 2 via [setDeviceId] and persisted so it
/// stays stable across launches (friends save it as our address).
class IdentityService {
  IdentityService(this._store);

  final KvStore _store;

  static const _kDeviceId = 'transfer.deviceId';
  static const _kName = 'transfer.displayName';
  static const _kPrivSeed = 'transfer.ed25519.seed';
  static const _kPub = 'transfer.ed25519.pub';

  final _algo = Ed25519();
  late SimpleKeyPair _keyPair;
  late SimplePublicKey _publicKey;

  String? _deviceId;
  late String _displayName;

  /// Firebase anonymous uid / inbox key. Null until sign-in (Phase 2).
  String? get deviceId => _deviceId;
  String get displayName => _displayName;

  /// Our base64 Ed25519 public key — the value friends save to verify us.
  String get publicKeyBase64 => base64.encode(_publicKey.bytes);

  /// Our short machine code (`a2:b1:c4:ff:07`) — the identity bound into signed
  /// messages and used for LAN discovery. Derived from the public key, so it's
  /// available immediately, offline, before any Firebase sign-in.
  String get myCode => deviceCodeFromPublicKey(publicKeyBase64);

  /// Loads the keypair + settings, generating the keypair on first run.
  Future<void> init() async {
    final seedB64 = _store.getString(_kPrivSeed);
    if (seedB64 == null) {
      _keyPair = await _algo.newKeyPair();
      _publicKey = await _keyPair.extractPublicKey();
      final seed = await _keyPair.extractPrivateKeyBytes();
      await _store.setString(_kPrivSeed, base64.encode(seed));
      await _store.setString(_kPub, base64.encode(_publicKey.bytes));
    } else {
      _keyPair = await _algo.newKeyPairFromSeed(base64.decode(seedB64));
      _publicKey = await _keyPair.extractPublicKey();
    }
    _displayName = _store.getString(_kName) ?? _defaultName();
    _deviceId = _store.getString(_kDeviceId);
  }

  Future<void> setDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _displayName = trimmed;
    await _store.setString(_kName, trimmed);
  }

  /// Called by the auth layer once the (stable) Firebase uid is known.
  Future<void> setDeviceId(String id) async {
    _deviceId = id;
    await _store.setString(_kDeviceId, id);
  }

  /// Signs [message] with our private key; returns the raw signature bytes.
  Future<Uint8List> sign(List<int> message) async {
    final sig = await _algo.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Verifies [signature] over [message] against a peer's base64 public key.
  Future<bool> verify(
    List<int> message,
    List<int> signature,
    String peerPublicKeyBase64,
  ) async {
    try {
      final pub = SimplePublicKey(
        base64.decode(peerPublicKeyBase64),
        type: KeyPairType.ed25519,
      );
      return _algo.verify(
        message,
        signature: Signature(signature, publicKey: pub),
      );
    } catch (_) {
      return false;
    }
  }

  /// Our shareable identity, for QR / copy-paste. The public key anchors our
  /// identity (and derives our [myCode]); the Firebase uid — empty until sign-in
  /// — is carried only so peers can reach us over the online path.
  Contact asShareableContact() => Contact(
        name: _displayName,
        deviceId: _deviceId ?? '',
        publicKey: publicKeyBase64,
      );

  String _defaultName() {
    try {
      final host = Platform.localHostname;
      if (host.trim().isNotEmpty) return host;
    } catch (_) {}
    return 'My Device';
  }
}

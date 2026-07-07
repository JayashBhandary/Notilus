import 'dart:convert';

import '../../utils/device_code.dart';

/// A saved peer for P2P file transfer. Exchanged once (QR / copy-paste) and
/// stored locally.
///
/// [publicKey] is the peer's base64 Ed25519 key — the identity anchor: it
/// verifies their signed messages and derives their short [code]. [code] is how
/// they're found on the LAN and shown in the UI. [deviceId] is their Firebase
/// anonymous uid, used *only* to route online transfers through RTDB (empty if
/// they hadn't signed in when the code was shared).
class Contact {
  const Contact({
    required this.name,
    required this.deviceId,
    required this.publicKey,
  });

  final String name;
  final String deviceId;
  final String publicKey; // base64 Ed25519 public key

  /// Short machine code, derived from [publicKey] — never stored or transmitted
  /// separately, so it can't drift from the key it identifies.
  String get code => deviceCodeFromPublicKey(publicKey);

  Contact copyWith({String? name, String? deviceId, String? publicKey}) =>
      Contact(
        name: name ?? this.name,
        deviceId: deviceId ?? this.deviceId,
        publicKey: publicKey ?? this.publicKey,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'deviceId': deviceId,
        'publicKey': publicKey,
      };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        name: (json['name'] ?? '') as String,
        deviceId: (json['deviceId'] ?? '') as String,
        publicKey: (json['publicKey'] ?? '') as String,
      );

  /// Compact wire form used for the "add contact" QR / copy-paste payload.
  /// Only the peer's routable identity is shared (never the private key).
  String toShareCode() => base64Url.encode(utf8.encode(jsonEncode({
        'v': 1,
        'id': deviceId,
        'pk': publicKey,
        'n': name,
      })));

  /// Parses a share code produced by [toShareCode]. Returns null if malformed.
  /// The importer supplies the local display name they want to file it under,
  /// falling back to the name embedded in the code.
  static Contact? fromShareCode(String code, {String? overrideName}) {
    try {
      final decoded =
          jsonDecode(utf8.decode(base64Url.decode(code.trim()))) as Map;
      final id = (decoded['id'] ?? '') as String;
      final pk = (decoded['pk'] ?? '') as String;
      // The public key is the identity anchor and is mandatory; the Firebase
      // uid may be empty (peer hadn't signed in — LAN transfer still works).
      if (pk.isEmpty) return null;
      final name =
          (overrideName?.trim().isNotEmpty ?? false)
              ? overrideName!.trim()
              : ((decoded['n'] ?? '') as String);
      return Contact(name: name, deviceId: id, publicKey: pk);
    } catch (_) {
      return null;
    }
  }
}

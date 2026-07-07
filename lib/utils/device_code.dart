import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Number of hash bytes in a machine code. 8 bytes = 64 bits, so forging a key
/// whose hash collides with a given code (a preimage attack) is infeasible —
/// which matters because the code is the sole token exchanged when adding a
/// contact by code. Rendered EUI-64 style: `a2:b1:c4:ff:07:3d:9e:11`.
const int _codeBytes = 8;

/// A short, human-readable machine code derived from an Ed25519 public key: the
/// first [_codeBytes] bytes of its SHA-256, formatted MAC-address style.
///
/// This is the machine's public identity for transfer — shown in the UI, used
/// as the LAN discovery id, bound into every signed message, and the token
/// friends type to add you. Deriving it from the (persistent) keypair means:
///  • stable across launches with no extra storage;
///  • available offline, before any Firebase sign-in (so LAN works with no net);
///  • self-authenticating — a peer claiming code X must present the public key
///    that hashes to X, so a resolved key is only trusted if it re-derives X.
///
/// The Firebase uid stays separate and is used *only* to route online transfers
/// through RTDB; it is never shown as the machine code.
String deviceCodeFromPublicKey(String publicKeyBase64) {
  // Real keys are valid base64; fall back to hashing the raw string so a
  // malformed key from a peer can't crash a lookup.
  List<int> bytes;
  try {
    bytes = base64.decode(base64.normalize(publicKeyBase64));
  } catch (_) {
    bytes = utf8.encode(publicKeyBase64);
  }
  final digest = sha256.convert(bytes).bytes;
  return digest
      .sublist(0, _codeBytes)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(':');
}

final RegExp _codePattern =
    RegExp('^([0-9a-f]{2}:){${_codeBytes - 1}}[0-9a-f]{2}\$');

/// Canonicalises user-entered code text (trims, lowercases, tolerates spaces or
/// dashes as separators) to the `aa:bb:…` form, or null if it isn't a valid
/// machine code.
String? normalizeDeviceCode(String input) {
  final s = input.trim().toLowerCase().replaceAll(RegExp(r'[\s-]'), ':');
  return _codePattern.hasMatch(s) ? s : null;
}

import 'dart:convert';

import '../../models/transfer/inbox_message.dart';
import 'identity_service.dart';

/// Deterministic JSON encoding with recursively sorted map keys. RTDB does not
/// preserve object key order, so we can't sign `jsonEncode(payload)` directly —
/// both sides must derive the exact same bytes. Lists keep their order.
String stableEncode(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((e) => e.toString()).toList()..sort();
    final parts =
        keys.map((k) => '${jsonEncode(k)}:${stableEncode(value[k])}');
    return '{${parts.join(',')}}';
  }
  if (value is List) {
    return '[${value.map(stableEncode).join(',')}]';
  }
  return jsonEncode(value);
}

/// The exact byte string that gets signed. Binds type/from/to/ts/payload so a
/// message can't be replayed to a different recipient or with altered content.
List<int> canonicalBytes(InboxMessage m) => utf8.encode(
      'v1|${m.type}|${m.from}|${m.to ?? ''}|${m.ts}|${stableEncode(m.payload)}',
    );

/// Builds a signed message from us to [to]. Both [from] and [to] are short
/// machine codes (not Firebase uids), so this works offline — no sign-in needed.
Future<InboxMessage> buildSignedMessage(
  IdentityService identity, {
  required String to,
  required String type,
  required Map<String, dynamic> payload,
  required int ts,
}) async {
  final base = InboxMessage(
    type: type,
    from: identity.myCode,
    to: to,
    ts: ts,
    payload: payload,
  );
  final sig = await identity.sign(canonicalBytes(base));
  return base.withSignature(base64.encode(sig));
}

/// How far [InboxMessage.ts] may drift from our clock before we treat a
/// (validly-signed) message as a stale replay. Covers reasonable clock skew;
/// every real signal is minted with the current time just before sending.
const Duration kMessageFreshness = Duration(minutes: 5);

/// Verifies [m] was signed by [senderPublicKey], addressed to us ([myId] is our
/// short machine code), and is fresh. Returns false on any mismatch (wrong
/// recipient, missing/forged signature, or a timestamp too far in the
/// past/future — a replay guard). [nowMs] is injectable for tests; it defaults
/// to the wall clock.
Future<bool> verifySignedMessage(
  IdentityService identity,
  InboxMessage m, {
  required String myId,
  required String senderPublicKey,
  Duration freshness = kMessageFreshness,
  int? nowMs,
}) async {
  if (m.to != myId) return false;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  if ((now - m.ts).abs() > freshness.inMilliseconds) return false;
  final sig = m.signature;
  if (sig == null) return false;
  try {
    return identity.verify(canonicalBytes(m), base64.decode(sig), senderPublicKey);
  } catch (_) {
    return false;
  }
}

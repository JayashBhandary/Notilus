/// A signaling message sitting in a peer's RTDB inbox.
///
/// Wire shape stored under `/users/{toId}/inbox/{pushId}`:
/// `{ type, from, ts, payload:{...}, sig? }`. [id] is the RTDB push id, present
/// only on received messages (used to delete them once handled).
class InboxMessage {
  const InboxMessage({
    required this.type,
    required this.from,
    required this.ts,
    this.to,
    this.id,
    this.payload = const {},
    this.signature,
  });

  /// Known message types (kept as strings on the wire).
  static const typeTransferRequest = 'transfer-request';
  static const typeTransferResponse = 'transfer-response';
  static const typeOffer = 'webrtc-offer';
  static const typeAnswer = 'webrtc-answer';
  static const typeIce = 'ice-candidate';
  static const typeCancel = 'cancel';

  final String? id;
  final String type;
  final String from; // sender's short machine code
  final String? to; // recipient's machine code (signed, guards against replay)
  final int ts; // epoch ms
  final Map<String, dynamic> payload;
  final String? signature; // base64 Ed25519 sig over the canonical form

  InboxMessage withId(String id) => InboxMessage(
        id: id,
        type: type,
        from: from,
        to: to,
        ts: ts,
        payload: payload,
        signature: signature,
      );

  InboxMessage withSignature(String sig) => InboxMessage(
        id: id,
        type: type,
        from: from,
        to: to,
        ts: ts,
        payload: payload,
        signature: sig,
      );

  Map<String, dynamic> toMap() => {
        'type': type,
        'from': from,
        if (to != null) 'to': to,
        'ts': ts,
        'payload': payload,
        if (signature != null) 'sig': signature,
      };

  factory InboxMessage.fromMap(String id, Map<String, dynamic> m) {
    final rawTs = m['ts'];
    return InboxMessage(
      id: id,
      type: (m['type'] ?? '') as String,
      from: (m['from'] ?? '') as String,
      to: m['to'] as String?,
      ts: rawTs is int ? rawTs : int.tryParse('$rawTs') ?? 0,
      payload: m['payload'] is Map
          ? (m['payload'] as Map).cast<String, dynamic>()
          : const {},
      signature: m['sig'] as String?,
    );
  }
}

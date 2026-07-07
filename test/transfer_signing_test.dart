import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/models/transfer/inbox_message.dart';
import 'package:notilus/services/transfer/identity_service.dart';
import 'package:notilus/services/transfer/kv_store.dart';
import 'package:notilus/services/transfer/signed_messages.dart';

Future<IdentityService> _identity(String deviceId) async {
  final id = IdentityService(MemoryKvStore());
  await id.init();
  await id.setDeviceId(deviceId);
  return id;
}

void main() {
  group('stableEncode', () {
    test('sorts map keys recursively and preserves list order', () {
      expect(stableEncode({'b': 1, 'a': 2}), '{"a":2,"b":1}');
      expect(
        stableEncode({
          'z': [
            {'y': 1, 'x': 2}
          ]
        }),
        '{"z":[{"x":2,"y":1}]}',
      );
    });
  });

  group('sign / verify', () {
    test('valid message from a known key to us verifies', () async {
      final alice = await _identity('alice');
      final bob = await _identity('bob');

      final msg = await buildSignedMessage(
        alice,
        to: 'bob',
        type: InboxMessage.typeTransferRequest,
        ts: 1720000000000,
        payload: {
          'requestId': 'r1',
          'files': [
            {'name': 'a.png', 'size': 10},
          ],
        },
      );

      // Bob verifies with Alice's public key, addressed to Bob → ok.
      expect(
        await verifySignedMessage(bob, msg,
            myId: 'bob',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: 1720000000000),
        isTrue,
      );
    });

    test('survives a JSON round-trip (RTDB may reorder keys)', () async {
      final alice = await _identity('alice');
      final bob = await _identity('bob');
      final msg = await buildSignedMessage(
        alice,
        to: 'bob',
        type: 'x',
        ts: 1,
        payload: {'b': 1, 'a': 2, 'nested': {'q': 9, 'p': 8}},
      );

      // Simulate storage reordering by rebuilding from a shuffled map.
      final wire = msg.toMap();
      final reordered = <String, dynamic>{
        'sig': wire['sig'],
        'payload': {'nested': {'p': 8, 'q': 9}, 'a': 2, 'b': 1},
        'ts': wire['ts'],
        'to': wire['to'],
        'from': wire['from'],
        'type': wire['type'],
      };
      final parsed = InboxMessage.fromMap('id', reordered);

      expect(
        await verifySignedMessage(bob, parsed,
            myId: 'bob',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: 1),
        isTrue,
      );
    });

    test('rejects tamper, wrong key, and wrong recipient', () async {
      final alice = await _identity('alice');
      final bob = await _identity('bob');
      final msg = await buildSignedMessage(
        alice,
        to: 'bob',
        type: 'x',
        ts: 1,
        payload: {'n': 1},
      );

      // Tampered payload.
      final tampered = InboxMessage(
        type: msg.type,
        from: msg.from,
        to: msg.to,
        ts: msg.ts,
        payload: {'n': 2},
        signature: msg.signature,
      );
      expect(
        await verifySignedMessage(bob, tampered,
            myId: 'bob',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: 1),
        isFalse,
      );

      // Wrong sender key (impersonation attempt).
      expect(
        await verifySignedMessage(bob, msg,
            myId: 'bob',
            senderPublicKey: bob.publicKeyBase64,
            nowMs: 1),
        isFalse,
      );

      // Addressed to someone else (replay to a different recipient).
      expect(
        await verifySignedMessage(bob, msg,
            myId: 'carol',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: 1),
        isFalse,
      );

      // Missing signature.
      final unsigned = InboxMessage(
        type: msg.type,
        from: msg.from,
        to: msg.to,
        ts: msg.ts,
        payload: msg.payload,
      );
      expect(
        await verifySignedMessage(bob, unsigned,
            myId: 'bob',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: 1),
        isFalse,
      );
    });

    test('rejects a stale or future timestamp (replay guard)', () async {
      final alice = await _identity('alice');
      final bob = await _identity('bob');
      const ts = 1720000000000;
      final msg = await buildSignedMessage(
        alice,
        to: 'bob',
        type: 'x',
        ts: ts,
        payload: {'n': 1},
      );

      Future<bool> verifyAt(int nowMs) => verifySignedMessage(
            bob,
            msg,
            myId: 'bob',
            senderPublicKey: alice.publicKeyBase64,
            nowMs: nowMs,
          );

      // Within the freshness window (±5 min) → ok.
      expect(await verifyAt(ts + 4 * 60 * 1000), isTrue);
      expect(await verifyAt(ts - 4 * 60 * 1000), isTrue);
      // Too old (replayed later) or too far in the future → rejected.
      expect(await verifyAt(ts + 6 * 60 * 1000), isFalse);
      expect(await verifyAt(ts - 6 * 60 * 1000), isFalse);
    });
  });
}

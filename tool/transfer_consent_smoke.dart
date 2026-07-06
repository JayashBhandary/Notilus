// Live two-peer test of the transfer request/consent handshake against real
// Firebase. Pure-Dart:  dart run tool/transfer_consent_smoke.dart
//
// Peer A sends a signed transfer-request to peer B; B verifies it's really from
// A and replies accept; A receives the signed accept. Also checks that forged /
// misaddressed messages are rejected. Requires transfer_config.dart filled in.
import 'dart:async';
import 'dart:io';

import 'package:notilus/config/transfer_config.dart';
import 'package:notilus/models/transfer/inbox_message.dart';
import 'package:notilus/services/transfer/firebase_auth_client.dart';
import 'package:notilus/services/transfer/identity_service.dart';
import 'package:notilus/services/transfer/kv_store.dart';
import 'package:notilus/services/transfer/rtdb_client.dart';
import 'package:notilus/services/transfer/signaling_service.dart';
import 'package:notilus/services/transfer/signed_messages.dart';

class _Peer {
  late final IdentityService id;
  late final FirebaseAuthClient auth;
  late final RtdbClient rtdb;
  late final SignalingService sig;

  Future<void> start(String label) async {
    final store = MemoryKvStore();
    id = IdentityService(store);
    await id.init();
    auth = FirebaseAuthClient(store);
    rtdb = RtdbClient(auth);
    sig = SignalingService(auth: auth, rtdb: rtdb, identity: id);
    await sig.start();
    print('   $label uid=${id.deviceId}');
  }

  Future<void> dispose() async {
    try {
      await rtdb.delete('users/${id.deviceId}/profile');
    } catch (_) {}
    await sig.stop();
    auth.close();
    rtdb.close();
  }
}

int get _now => DateTime.now().millisecondsSinceEpoch;

Future<void> main() async {
  if (!TransferConfig.isConfigured) {
    stderr.writeln('✗ transfer_config.dart is not configured.');
    exit(1);
  }

  final a = _Peer();
  final b = _Peer();
  final accepted = Completer<bool>();

  try {
    print('1. starting two peers…');
    await a.start('A');
    await b.start('B');

    // B: verify incoming requests are really from A, then accept.
    b.sig.messages.listen((m) async {
      if (m.type != InboxMessage.typeTransferRequest) return;
      final ok = await verifySignedMessage(b.id, m,
          myDeviceId: b.id.deviceId!, senderPublicKey: a.id.publicKeyBase64);
      print('   B received request (verified=$ok)');
      if (m.id != null) await b.sig.deleteInboxMessage(m.id!);
      if (!ok) return;
      final resp = await buildSignedMessage(
        b.id,
        to: m.from,
        type: InboxMessage.typeTransferResponse,
        ts: _now,
        payload: {'requestId': m.payload['requestId'], 'accepted': true},
      );
      await b.sig.send(m.from, resp);
    });

    // A: receive the signed response.
    a.sig.messages.listen((m) async {
      if (m.type != InboxMessage.typeTransferResponse) return;
      final ok = await verifySignedMessage(a.id, m,
          myDeviceId: a.id.deviceId!, senderPublicKey: b.id.publicKeyBase64);
      if (m.id != null) await a.sig.deleteInboxMessage(m.id!);
      if (ok && !accepted.isCompleted) {
        accepted.complete(m.payload['accepted'] == true);
      }
    });

    await Future<void>.delayed(const Duration(seconds: 1)); // snapshots settle

    print('2. A → signed transfer-request to B…');
    final req = await buildSignedMessage(
      a.id,
      to: b.id.deviceId!,
      type: InboxMessage.typeTransferRequest,
      ts: _now,
      payload: {
        'requestId': 'req-1',
        'count': 1,
        'files': [
          {'name': 'demo.bin', 'size': 1048576}
        ],
      },
    );
    await a.sig.send(b.id.deviceId!, req);

    print('3. awaiting B\'s signed accept (≤20s)…');
    final result = await accepted.future.timeout(const Duration(seconds: 20));
    if (!result) throw Exception('expected accepted=true');
    print('   ✓ handshake accepted end-to-end');

    print('4. negative checks (forgery rejection)…');
    final good = await buildSignedMessage(a.id,
        to: b.id.deviceId!, type: 'x', ts: _now, payload: {'n': 1});
    final tampered = InboxMessage(
        type: good.type,
        from: good.from,
        to: good.to,
        ts: good.ts,
        payload: {'n': 2},
        signature: good.signature);
    final checks = {
      'valid': await verifySignedMessage(b.id, good,
          myDeviceId: b.id.deviceId!, senderPublicKey: a.id.publicKeyBase64),
      'tampered-rejected': !await verifySignedMessage(b.id, tampered,
          myDeviceId: b.id.deviceId!, senderPublicKey: a.id.publicKeyBase64),
      'wrong-key-rejected': !await verifySignedMessage(b.id, good,
          myDeviceId: b.id.deviceId!, senderPublicKey: b.id.publicKeyBase64),
      'wrong-recipient-rejected': !await verifySignedMessage(b.id, good,
          myDeviceId: 'someone-else', senderPublicKey: a.id.publicKeyBase64),
    };
    print('   $checks');
    if (checks.values.any((v) => v == false)) {
      throw Exception('a forgery check failed');
    }

    print('\n✅ CONSENT HANDSHAKE SMOKE TEST PASSED');
  } catch (e) {
    stderr.writeln('\n✗ FAILED: $e');
    exitCode = 1;
  } finally {
    await a.dispose();
    await b.dispose();
  }
  exit(exitCode);
}

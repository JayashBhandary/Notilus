// Live end-to-end smoke test of the P2P signaling substrate against the real
// Firebase project. Pure-Dart (no Flutter engine), so run it directly:
//
//   dart run tool/transfer_smoke.dart
//
// It: signs in anonymously → publishes profile → opens the inbox SSE stream →
// sends a message to its own inbox → confirms it arrives over SSE → checks
// presence → cleans up. Requires lib/config/transfer_config.dart to be filled.
import 'dart:async';
import 'dart:io';

import 'package:notilus/config/transfer_config.dart';
import 'package:notilus/models/transfer/inbox_message.dart';
import 'package:notilus/services/transfer/firebase_auth_client.dart';
import 'package:notilus/services/transfer/identity_service.dart';
import 'package:notilus/services/transfer/kv_store.dart';
import 'package:notilus/services/transfer/rtdb_client.dart';
import 'package:notilus/services/transfer/signaling_service.dart';

Future<void> main() async {
  if (!TransferConfig.isConfigured) {
    stderr.writeln('✗ transfer_config.dart is not configured — fill it in.');
    exit(1);
  }

  final store = MemoryKvStore();
  final identity = IdentityService(store);
  await identity.init();
  final auth = FirebaseAuthClient(store);
  final rtdb = RtdbClient(auth);
  final sig = SignalingService(auth: auth, rtdb: rtdb, identity: identity);

  final gotIt = Completer<InboxMessage>();
  final sub = sig.messages.listen((m) {
    print('   ← inbox event: type=${m.type} from=${m.from} payload=${m.payload}');
    if (m.type == 'smoke-test' && !gotIt.isCompleted) gotIt.complete(m);
  });

  try {
    print('1. starting signaling (anon sign-in + profile + SSE)…');
    await sig.start();
    final uid = auth.uid!;
    print('   uid=$uid  name="${identity.displayName}"  pubkey=${identity.publicKeyBase64.substring(0, 12)}…');

    // Let the initial inbox snapshot arrive before sending live.
    await Future<void>.delayed(const Duration(seconds: 1));

    print('2. sending a self message…');
    await sig.send(
      uid,
      InboxMessage(
        type: 'smoke-test',
        from: uid,
        ts: DateTime.now().millisecondsSinceEpoch,
        payload: {'hello': 'world'},
      ),
    );

    print('3. awaiting it over the SSE stream (≤15s)…');
    final msg = await gotIt.future.timeout(const Duration(seconds: 15));
    print('   ✓ received via SSE (push id=${msg.id})');

    print('4. presence check: isOnline(self) = ${await sig.isOnline(uid)}');

    print('5. cleanup…');
    // Note: the rules grant .write on profile/inbox children only, not on the
    // parent /users/$uid node — so we delete the children we own, not the node.
    if (msg.id != null) await sig.deleteInboxMessage(msg.id!);
    await rtdb.delete('users/$uid/profile');

    print('\n✅ SIGNALING SMOKE TEST PASSED');
  } catch (e) {
    stderr.writeln('\n✗ SMOKE TEST FAILED: $e');
    exitCode = 1;
  } finally {
    await sub.cancel();
    await sig.stop();
    auth.close();
    rtdb.close();
  }
  exit(exitCode);
}

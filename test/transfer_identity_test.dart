import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/models/transfer/contact.dart';
import 'package:notilus/services/transfer/contacts_store.dart';
import 'package:notilus/services/transfer/identity_service.dart';
import 'package:notilus/services/transfer/kv_store.dart';
import 'package:notilus/utils/device_code.dart';

void main() {
  group('IdentityService', () {
    test('generates a keypair on first run and reuses it after restart',
        () async {
      final store = MemoryKvStore();
      final a = IdentityService(store);
      await a.init();
      final pub1 = a.publicKeyBase64;
      expect(pub1, isNotEmpty);

      // Re-init from the same store = same identity (persisted seed).
      final b = IdentityService(store);
      await b.init();
      expect(b.publicKeyBase64, pub1);
    });

    test('sign/verify round-trips; tamper and wrong-key are rejected',
        () async {
      final me = IdentityService(MemoryKvStore());
      await me.init();

      final msg = utf8.encode('transfer-request:3 files');
      final sig = await me.sign(msg);
      expect(await me.verify(msg, sig, me.publicKeyBase64), isTrue);

      // Tampered message fails.
      final bad = utf8.encode('transfer-request:9 files');
      expect(await me.verify(bad, sig, me.publicKeyBase64), isFalse);

      // A different identity's key fails.
      final other = IdentityService(MemoryKvStore());
      await other.init();
      expect(await me.verify(msg, sig, other.publicKeyBase64), isFalse);
    });

    test('myCode is derived from the key and stable across restart', () async {
      final store = MemoryKvStore();
      final a = IdentityService(store);
      await a.init();
      expect(a.myCode, deviceCodeFromPublicKey(a.publicKeyBase64));
      // 8 bytes → 8 colon-separated hex groups (EUI-64 style).
      expect(a.myCode, matches(RegExp(r'^([0-9a-f]{2}:){7}[0-9a-f]{2}$')));
      expect(normalizeDeviceCode(a.myCode.toUpperCase()), a.myCode);
      expect(normalizeDeviceCode('not a code'), isNull);

      final b = IdentityService(store);
      await b.init();
      expect(b.myCode, a.myCode); // same persisted key → same code
    });

    test('deviceId and display name persist; shareable before sign-in',
        () async {
      final store = MemoryKvStore();
      final a = IdentityService(store);
      await a.init();
      expect(a.deviceId, isNull);
      // Shareable even without a Firebase uid (LAN-only): uid is empty, and the
      // code anchors identity.
      expect(a.asShareableContact().deviceId, '');
      expect(a.asShareableContact().code, a.myCode);

      await a.setDeviceId('firebase-uid-123');
      await a.setDisplayName('Jayash Mac');

      final b = IdentityService(store);
      await b.init();
      expect(b.deviceId, 'firebase-uid-123');
      expect(b.displayName, 'Jayash Mac');
      expect(b.asShareableContact().deviceId, 'firebase-uid-123');
    });
  });

  group('Contact share code', () {
    test('round-trips through the share code', () {
      const c = Contact(
        name: 'Bob',
        deviceId: 'uid-bob',
        publicKey: 'cHVia2V5',
      );
      final parsed = Contact.fromShareCode(c.toShareCode());
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, 'uid-bob');
      expect(parsed.publicKey, 'cHVia2V5');
      expect(parsed.name, 'Bob');
    });

    test('override name wins; malformed code returns null', () {
      const c = Contact(name: 'Bob', deviceId: 'uid-bob', publicKey: 'cHViaw==');
      final parsed =
          Contact.fromShareCode(c.toShareCode(), overrideName: 'Work Laptop');
      expect(parsed!.name, 'Work Laptop');
      expect(Contact.fromShareCode('not-valid-base64!!'), isNull);
    });

    test('empty uid is allowed (LAN-only); empty public key is rejected', () {
      // A peer who hasn't signed into Firebase shares with an empty uid — still
      // valid, since the public key anchors identity and LAN doesn't need it.
      const lanOnly = Contact(name: 'Bob', deviceId: '', publicKey: 'cHViaw==');
      final parsed = Contact.fromShareCode(lanOnly.toShareCode());
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, '');
      expect(parsed.code, deviceCodeFromPublicKey('cHViaw=='));

      // No public key → no identity → rejected.
      const noKey = Contact(name: 'X', deviceId: 'uid', publicKey: '');
      expect(Contact.fromShareCode(noKey.toShareCode()), isNull);
    });
  });

  group('Contact.code', () {
    test('is derived from the public key: same key → same code', () {
      const a = Contact(name: 'A', deviceId: 'uid-a', publicKey: 'AAAA');
      const aAlt = Contact(name: 'A2', deviceId: 'uid-a2', publicKey: 'AAAA');
      const b = Contact(name: 'B', deviceId: 'uid-b', publicKey: 'BBBB');
      expect(a.code, aAlt.code); // key, not uid, determines the code
      expect(a.code, isNot(b.code));
    });
  });

  group('ContactsStore', () {
    // Keyed by code (== public key), so uid/name differences don't create dupes.
    const pkZ = 'AAAA', pkA = 'BBBB';
    final codeZ = deviceCodeFromPublicKey(pkZ);
    final codeA = deviceCodeFromPublicKey(pkA);

    test('upsert dedups by code, persists, and reloads sorted', () async {
      final store = MemoryKvStore();
      final contacts = ContactsStore(store);

      await contacts.upsert(
          const Contact(name: 'Zed', deviceId: 'z', publicKey: pkZ));
      await contacts.upsert(
          const Contact(name: 'Amy', deviceId: 'a', publicKey: pkA));
      // Same key (→ same code), different uid → update in place, not a dupe.
      await contacts.upsert(
          const Contact(name: 'Zed 2', deviceId: 'z2', publicKey: pkZ));

      expect(contacts.contacts.length, 2);
      expect(contacts.contacts.first.name, 'Amy'); // sorted
      expect(contacts.byCode(codeZ)!.name, 'Zed 2');
      expect(contacts.byCode(codeZ)!.deviceId, 'z2');

      // Reload from the same store.
      final reloaded = ContactsStore(store);
      expect(reloaded.contacts.length, 2);
      expect(reloaded.byCode(codeA)!.deviceId, 'a');
      expect(reloaded.byCode('ff:ff:ff:ff:ff'), isNull);
    });

    test('rename and remove by code', () async {
      final contacts = ContactsStore(MemoryKvStore());
      await contacts.upsert(
          const Contact(name: 'Bob', deviceId: 'b', publicKey: pkZ));
      await contacts.rename(codeZ, 'Bobby');
      expect(contacts.byCode(codeZ)!.name, 'Bobby');
      await contacts.remove(codeZ);
      expect(contacts.byCode(codeZ), isNull);
      expect(contacts.isEmpty, isTrue);
    });
  });
}

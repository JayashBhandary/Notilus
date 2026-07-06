import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/models/transfer/contact.dart';
import 'package:notilus/services/transfer/contacts_store.dart';
import 'package:notilus/services/transfer/identity_service.dart';
import 'package:notilus/services/transfer/kv_store.dart';

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

    test('deviceId and display name persist', () async {
      final store = MemoryKvStore();
      final a = IdentityService(store);
      await a.init();
      expect(a.deviceId, isNull);
      expect(a.asShareableContact(), isNull); // no id yet

      await a.setDeviceId('firebase-uid-123');
      await a.setDisplayName('Jayash Mac');

      final b = IdentityService(store);
      await b.init();
      expect(b.deviceId, 'firebase-uid-123');
      expect(b.displayName, 'Jayash Mac');
      expect(b.asShareableContact()!.deviceId, 'firebase-uid-123');
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
      const c = Contact(name: 'Bob', deviceId: 'uid-bob', publicKey: 'k');
      final parsed =
          Contact.fromShareCode(c.toShareCode(), overrideName: 'Work Laptop');
      expect(parsed!.name, 'Work Laptop');
      expect(Contact.fromShareCode('not-valid-base64!!'), isNull);
    });
  });

  group('ContactsStore', () {
    test('upsert dedups by deviceId, persists, and reloads sorted', () async {
      final store = MemoryKvStore();
      final contacts = ContactsStore(store);

      await contacts.upsert(
          const Contact(name: 'Zed', deviceId: 'z', publicKey: 'kz'));
      await contacts.upsert(
          const Contact(name: 'Amy', deviceId: 'a', publicKey: 'ka'));
      // Same deviceId again → update in place, not a duplicate.
      await contacts.upsert(
          const Contact(name: 'Zed 2', deviceId: 'z', publicKey: 'kz2'));

      expect(contacts.contacts.length, 2);
      expect(contacts.contacts.first.name, 'Amy'); // sorted
      expect(contacts.byDeviceId('z')!.name, 'Zed 2');
      expect(contacts.byDeviceId('z')!.publicKey, 'kz2');

      // Reload from the same store.
      final reloaded = ContactsStore(store);
      expect(reloaded.contacts.length, 2);
      expect(reloaded.byDeviceId('a')!.publicKey, 'ka');
    });

    test('isTrusted requires saved id AND matching public key', () async {
      final contacts = ContactsStore(MemoryKvStore());
      await contacts.upsert(
          const Contact(name: 'Bob', deviceId: 'b', publicKey: 'realkey'));

      expect(contacts.isTrusted('b', 'realkey'), isTrue);
      expect(contacts.isTrusted('b', 'forgedkey'), isFalse); // impersonation
      expect(contacts.isTrusted('unknown', 'realkey'), isFalse);
    });

    test('rename and remove', () async {
      final contacts = ContactsStore(MemoryKvStore());
      await contacts.upsert(
          const Contact(name: 'Bob', deviceId: 'b', publicKey: 'k'));
      await contacts.rename('b', 'Bobby');
      expect(contacts.byDeviceId('b')!.name, 'Bobby');
      await contacts.remove('b');
      expect(contacts.byDeviceId('b'), isNull);
      expect(contacts.isEmpty, isTrue);
    });
  });
}

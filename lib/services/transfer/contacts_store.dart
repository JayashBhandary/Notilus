import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/transfer/contact.dart';
import 'kv_store.dart';

/// Persistent list of saved transfer peers. Keyed by [Contact.deviceId] so a
/// peer can't be added twice; re-adding an existing id updates it in place.
class ContactsStore extends ChangeNotifier {
  ContactsStore(this._store) {
    _load();
  }

  final KvStore _store;
  static const _kContacts = 'transfer.contacts';

  final List<Contact> _contacts = [];

  List<Contact> get contacts => List.unmodifiable(_contacts);
  bool get isEmpty => _contacts.isEmpty;

  Contact? byDeviceId(String deviceId) {
    for (final c in _contacts) {
      if (c.deviceId == deviceId) return c;
    }
    return null;
  }

  /// True if an inbox message from [deviceId] can be trusted as this contact —
  /// the id must be saved and the signing public key must match what we saved.
  bool isTrusted(String deviceId, String publicKey) {
    final c = byDeviceId(deviceId);
    return c != null && c.publicKey == publicKey;
  }

  /// Adds a new contact or updates the existing one with the same deviceId.
  Future<void> upsert(Contact contact) async {
    final i = _contacts.indexWhere((c) => c.deviceId == contact.deviceId);
    if (i >= 0) {
      _contacts[i] = contact;
    } else {
      _contacts.add(contact);
    }
    _sort();
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String deviceId) async {
    final before = _contacts.length;
    _contacts.removeWhere((c) => c.deviceId == deviceId);
    if (_contacts.length != before) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> rename(String deviceId, String newName) async {
    final i = _contacts.indexWhere((c) => c.deviceId == deviceId);
    if (i < 0 || newName.trim().isEmpty) return;
    _contacts[i] = _contacts[i].copyWith(name: newName.trim());
    _sort();
    await _persist();
    notifyListeners();
  }

  void _load() {
    final raw = _store.getString(_kContacts);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      _contacts
        ..clear()
        ..addAll(list.map((e) => Contact.fromJson((e as Map).cast())));
      _sort();
    } catch (_) {
      // Corrupt store — start clean rather than crash.
      _contacts.clear();
    }
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_contacts.map((c) => c.toJson()).toList());
    await _store.setString(_kContacts, raw);
  }

  void _sort() => _contacts
      .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

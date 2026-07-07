import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/transfer/contact.dart';
import 'kv_store.dart';

/// Persistent list of saved transfer peers. Keyed by [Contact.code] (the
/// identity, derived from the public key) so a peer can't be added twice and
/// LAN-only contacts — which may share an empty Firebase uid — stay distinct;
/// re-adding an existing code updates it in place.
class ContactsStore extends ChangeNotifier {
  ContactsStore(this._store) {
    _load();
  }

  final KvStore _store;
  static const _kContacts = 'transfer.contacts';

  final List<Contact> _contacts = [];

  List<Contact> get contacts => List.unmodifiable(_contacts);
  bool get isEmpty => _contacts.isEmpty;

  /// The saved contact with this short [Contact.code], or null. This is the
  /// primary lookup — messages and LAN discovery identify peers by code.
  Contact? byCode(String code) {
    for (final c in _contacts) {
      if (c.code == code) return c;
    }
    return null;
  }

  /// Adds a new contact or updates the existing one with the same code.
  Future<void> upsert(Contact contact) async {
    final i = _contacts.indexWhere((c) => c.code == contact.code);
    if (i >= 0) {
      _contacts[i] = contact;
    } else {
      _contacts.add(contact);
    }
    _sort();
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String code) async {
    final before = _contacts.length;
    _contacts.removeWhere((c) => c.code == code);
    if (_contacts.length != before) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> rename(String code, String newName) async {
    final i = _contacts.indexWhere((c) => c.code == code);
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

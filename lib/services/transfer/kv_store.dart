/// Minimal key/value persistence abstraction so the transfer services stay
/// pure-Dart (no Flutter plugin dependency) and can be exercised with real
/// network calls via `dart run`. The app wires in a shared_preferences-backed
/// implementation (`PrefsKvStore`); tests/tools use [MemoryKvStore].
abstract class KvStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class MemoryKvStore implements KvStore {
  MemoryKvStore([Map<String, String>? initial]) {
    if (initial != null) _m.addAll(initial);
  }
  final Map<String, String> _m = {};

  @override
  String? getString(String key) => _m[key];

  @override
  Future<void> setString(String key, String value) async => _m[key] = value;

  @override
  Future<void> remove(String key) async => _m.remove(key);
}

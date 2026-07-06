import 'package:shared_preferences/shared_preferences.dart';

import 'kv_store.dart';

/// shared_preferences-backed [KvStore] used by the running app.
class PrefsKvStore implements KvStore {
  PrefsKvStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

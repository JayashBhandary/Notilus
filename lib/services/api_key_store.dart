import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'llm/llm_client.dart';

/// API keys live in the OS keychain (macOS Keychain / Windows Credential
/// Manager / libsecret), never in shared_preferences.
class ApiKeyStore {
  // The data-protection keychain requires a keychain-access-groups
  // entitlement (signed team) on macOS; the legacy file keychain doesn't.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  String _key(LlmProviderKind kind) => 'llm_api_key_${kind.id}';

  Future<String> read(LlmProviderKind kind) async =>
      await _storage.read(key: _key(kind)) ?? '';

  Future<void> write(LlmProviderKind kind, String value) async {
    if (value.isEmpty) {
      await _storage.delete(key: _key(kind));
    } else {
      await _storage.write(key: _key(kind), value: value);
    }
  }
}

import 'package:flutter/cupertino.dart';

import '../services/api_key_store.dart';
import '../services/llm/anthropic_client.dart';
import '../services/llm/gemini_client.dart';
import '../services/llm/llm_client.dart';
import '../services/llm/ollama_client.dart';
import '../services/llm/openai_client.dart';
import '../services/settings_store.dart';
import '../services/tray_service.dart';

enum AppThemeMode { system, light, dark }

extension AppThemeModeStorage on AppThemeMode {
  String get id {
    switch (this) {
      case AppThemeMode.system:
        return 'system';
      case AppThemeMode.light:
        return 'light';
      case AppThemeMode.dark:
        return 'dark';
    }
  }

  static AppThemeMode fromId(String id) {
    switch (id) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      default:
        return AppThemeMode.system;
    }
  }
}

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._store, {ApiKeyStore? apiKeys})
      : _apiKeyStore = apiKeys ?? ApiKeyStore();

  final SettingsStore _store;
  final ApiKeyStore _apiKeyStore;

  String _host = SettingsStore.defaultHost;
  LlmProviderKind _provider = LlmProviderKind.ollama;
  String _compatBaseUrl = '';
  final Map<LlmProviderKind, String?> _models = {};
  final Map<LlmProviderKind, String> _apiKeys = {};
  final Map<LlmProviderKind, List<String>> _availableModels = {};
  final Map<LlmProviderKind, bool> _connected = {};
  double _temperature = 0.7;
  bool _loaded = false;
  AppThemeMode _themeMode = AppThemeMode.system;
  bool _sidebarCollapsed = false;
  bool _rightPanelCollapsed = false;
  bool _backgroundReception = true;
  String _transferDestination = '';
  bool _preferLocalNetwork = true;

  String get host => _host;
  LlmProviderKind get provider => _provider;
  String get compatBaseUrl => _compatBaseUrl;
  double get temperature => _temperature;
  bool get loaded => _loaded;
  AppThemeMode get themeMode => _themeMode;
  bool get sidebarCollapsed => _sidebarCollapsed;
  bool get rightPanelCollapsed => _rightPanelCollapsed;
  bool get backgroundReception => _backgroundReception;

  /// Selected model for the active provider.
  String? get model => _models[_provider];
  String? modelFor(LlmProviderKind kind) => _models[kind];

  String apiKeyFor(LlmProviderKind kind) => _apiKeys[kind] ?? '';

  /// Discovered models for the active provider.
  List<String> get availableModels => modelsFor(_provider);
  List<String> modelsFor(LlmProviderKind kind) =>
      _availableModels[kind] ?? const [];

  bool get connected => connectedFor(_provider);
  bool connectedFor(LlmProviderKind kind) => _connected[kind] ?? false;

  /// Whether the provider has enough configuration to attempt a request.
  bool isConfigured(LlmProviderKind kind) {
    switch (kind) {
      case LlmProviderKind.ollama:
        return true;
      case LlmProviderKind.anthropic:
      case LlmProviderKind.gemini:
      case LlmProviderKind.openai:
        return apiKeyFor(kind).isNotEmpty;
      case LlmProviderKind.openaiCompat:
        return _compatBaseUrl.isNotEmpty;
    }
  }

  List<LlmProviderKind> get configuredProviders =>
      LlmProviderKind.values.where(isConfigured).toList();

  /// Builds a throwaway client for [kind] from the current configuration.
  LlmClient clientFor(LlmProviderKind kind) {
    switch (kind) {
      case LlmProviderKind.ollama:
        return OllamaClient(_host);
      case LlmProviderKind.anthropic:
        return AnthropicClient(apiKey: apiKeyFor(kind));
      case LlmProviderKind.gemini:
        return GeminiClient(apiKey: apiKeyFor(kind));
      case LlmProviderKind.openai:
        return OpenAIClient(apiKey: apiKeyFor(kind));
      case LlmProviderKind.openaiCompat:
        return OpenAIClient(apiKey: apiKeyFor(kind), baseUrl: _compatBaseUrl);
    }
  }

  /// Client for the app-wide default provider.
  LlmClient defaultClient() => clientFor(_provider);

  /// Folder for received files; empty means the default (`~/Downloads/Notilus`).
  String get transferDestination => _transferDestination;

  /// Whether to try the LAN-direct path before falling back to Firebase.
  bool get preferLocalNetwork => _preferLocalNetwork;

  /// Resolves [themeMode] (which may be `system`) to a concrete brightness
  /// using the platform's current brightness.
  Brightness resolveBrightness(Brightness platformBrightness) {
    switch (_themeMode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.system:
        return platformBrightness;
    }
  }

  Future<void> load() async {
    _host = await _store.getHost();
    _provider = LlmProviderKindInfo.fromId(await _store.getLlmProvider());
    _compatBaseUrl = await _store.getCompatBaseUrl();
    for (final kind in LlmProviderKind.values) {
      _models[kind] = await _store.getModelFor(kind.id);
      if (kind.supportsApiKey) {
        try {
          _apiKeys[kind] = await _apiKeyStore.read(kind);
        } catch (_) {
          // Keychain unavailable (e.g. no libsecret) — treat as unset.
          _apiKeys[kind] = '';
        }
      }
    }
    _temperature = await _store.getTemperature();
    _themeMode = AppThemeModeStorage.fromId(await _store.getThemeMode());
    _sidebarCollapsed = await _store.getSidebarCollapsed();
    _rightPanelCollapsed = await _store.getRightPanelCollapsed();
    _backgroundReception = await _store.getBackgroundReception();
    TrayService.instance.backgroundEnabled = _backgroundReception;
    _transferDestination = await _store.getTransferDestination();
    _preferLocalNetwork = await _store.getPreferLocalNetwork();
    _loaded = true;
    notifyListeners();
    await refreshModels();
  }

  Future<void> setBackgroundReception(bool enabled) async {
    _backgroundReception = enabled;
    await _store.setBackgroundReception(enabled);
    TrayService.instance.backgroundEnabled = enabled;
    notifyListeners();
  }

  Future<void> setTransferDestination(String path) async {
    _transferDestination = path.trim();
    await _store.setTransferDestination(_transferDestination);
    notifyListeners();
  }

  Future<void> setPreferLocalNetwork(bool enabled) async {
    _preferLocalNetwork = enabled;
    await _store.setPreferLocalNetwork(enabled);
    notifyListeners();
  }

  Future<void> setSidebarCollapsed(bool collapsed) async {
    _sidebarCollapsed = collapsed;
    await _store.setSidebarCollapsed(collapsed);
    notifyListeners();
  }

  void toggleSidebar() => setSidebarCollapsed(!_sidebarCollapsed);

  Future<void> setRightPanelCollapsed(bool collapsed) async {
    _rightPanelCollapsed = collapsed;
    await _store.setRightPanelCollapsed(collapsed);
    notifyListeners();
  }

  void toggleRightPanel() => setRightPanelCollapsed(!_rightPanelCollapsed);

  Future<void> setProvider(LlmProviderKind kind) async {
    _provider = kind;
    await _store.setLlmProvider(kind.id);
    notifyListeners();
    if (modelsFor(kind).isEmpty) {
      await refreshModelsFor(kind);
    }
  }

  Future<void> setHost(String host) async {
    _host = host;
    await _store.setHost(host);
    notifyListeners();
  }

  Future<void> setApiKey(LlmProviderKind kind, String key) async {
    _apiKeys[kind] = key.trim();
    try {
      await _apiKeyStore.write(kind, _apiKeys[kind]!);
    } catch (_) {
      // Keychain write failed — the key still works for this session.
    }
    notifyListeners();
  }

  Future<void> setCompatBaseUrl(String url) async {
    _compatBaseUrl = url.trim();
    await _store.setCompatBaseUrl(_compatBaseUrl);
    notifyListeners();
  }

  Future<void> setModel(String? model) => setModelFor(_provider, model);

  Future<void> setModelFor(LlmProviderKind kind, String? model) async {
    _models[kind] = model;
    await _store.setModelFor(kind.id, model);
    notifyListeners();
  }

  Future<void> setTemperature(double t) async {
    _temperature = t;
    await _store.setTemperature(t);
    notifyListeners();
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    _themeMode = mode;
    await _store.setThemeMode(mode.id);
    notifyListeners();
  }

  Future<void> refreshModels() => refreshModelsFor(_provider);

  Future<void> refreshModelsFor(LlmProviderKind kind) async {
    if (!isConfigured(kind)) {
      _availableModels[kind] = [];
      _connected[kind] = false;
      notifyListeners();
      return;
    }
    try {
      final models = await clientFor(kind).listModels();
      _availableModels[kind] = models;
      _connected[kind] = true;
      if (_models[kind] == null && models.isNotEmpty) {
        _models[kind] = models.first;
        await _store.setModelFor(kind.id, models.first);
      }
    } catch (_) {
      _availableModels[kind] = [];
      _connected[kind] = false;
    }
    notifyListeners();
  }
}

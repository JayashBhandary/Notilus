import 'package:flutter/cupertino.dart';

import '../services/ollama_service.dart';
import '../services/settings_store.dart';

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
  SettingsProvider(this._store);

  final SettingsStore _store;

  String _host = SettingsStore.defaultHost;
  String? _model;
  double _temperature = 0.7;
  List<String> _availableModels = [];
  bool _connected = false;
  bool _loaded = false;
  AppThemeMode _themeMode = AppThemeMode.system;
  bool _sidebarCollapsed = false;
  bool _rightPanelCollapsed = false;

  String get host => _host;
  String? get model => _model;
  double get temperature => _temperature;
  List<String> get availableModels => _availableModels;
  bool get connected => _connected;
  bool get loaded => _loaded;
  AppThemeMode get themeMode => _themeMode;
  bool get sidebarCollapsed => _sidebarCollapsed;
  bool get rightPanelCollapsed => _rightPanelCollapsed;

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
    _model = await _store.getModel();
    _temperature = await _store.getTemperature();
    _themeMode = AppThemeModeStorage.fromId(await _store.getThemeMode());
    _sidebarCollapsed = await _store.getSidebarCollapsed();
    _rightPanelCollapsed = await _store.getRightPanelCollapsed();
    _loaded = true;
    notifyListeners();
    await refreshModels();
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

  Future<void> setHost(String host) async {
    _host = host;
    await _store.setHost(host);
    notifyListeners();
    await refreshModels();
  }

  Future<void> setModel(String? model) async {
    _model = model;
    await _store.setModel(model);
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

  Future<void> refreshModels() async {
    final svc = OllamaService(_host);
    try {
      _availableModels = await svc.listModels();
      _connected = true;
      if (_model == null && _availableModels.isNotEmpty) {
        _model = _availableModels.first;
        await _store.setModel(_model);
      }
    } catch (_) {
      _availableModels = [];
      _connected = false;
    }
    notifyListeners();
  }
}

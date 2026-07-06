import 'package:flutter/cupertino.dart';

import '../services/ollama_service.dart';
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
  bool _backgroundReception = true;
  String _transferDestination = '';
  bool _preferLocalNetwork = true;

  String get host => _host;
  String? get model => _model;
  double get temperature => _temperature;
  List<String> get availableModels => _availableModels;
  bool get connected => _connected;
  bool get loaded => _loaded;
  AppThemeMode get themeMode => _themeMode;
  bool get sidebarCollapsed => _sidebarCollapsed;
  bool get rightPanelCollapsed => _rightPanelCollapsed;
  bool get backgroundReception => _backgroundReception;

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
    _model = await _store.getModel();
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

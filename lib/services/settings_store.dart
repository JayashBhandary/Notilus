import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/workflow.dart';

class SettingsStore {
  static const _kHost = 'ollama_host';
  static const _kModel = 'default_model'; // legacy: the Ollama model
  static const _kLlmProvider = 'llm_provider';
  static const _kCompatBaseUrl = 'openai_compat_base_url';
  static const _kTemperature = 'temperature';
  static const _kWorkflows = 'workflows_json';
  static const _kThemeMode = 'theme_mode';
  static const _kDupFinderPrefs = 'duplicate_finder_prefs';
  static const _kSidebarCollapsed = 'sidebar_collapsed';
  static const _kRightPanelCollapsed = 'right_panel_collapsed';
  static const _kBackgroundReception = 'background_reception';
  static const _kTransferDestination = 'transfer_destination';
  static const _kPreferLocalNetwork = 'prefer_local_network';

  static const String defaultHost = 'http://localhost:11434';

  /// Whether Notilus keeps running in the tray to receive transfers when the
  /// window is closed. Defaults on — it's the point of the feature.
  Future<bool> getBackgroundReception() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kBackgroundReception) ?? true;
  }

  Future<void> setBackgroundReception(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackgroundReception, enabled);
  }

  /// Folder for received files. Empty string means "use the default"
  /// (`~/Downloads/Notilus`, resolved in `TransferController`).
  Future<String> getTransferDestination() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kTransferDestination) ?? '';
  }

  Future<void> setTransferDestination(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_kTransferDestination);
    } else {
      await prefs.setString(_kTransferDestination, trimmed);
    }
  }

  /// Whether to try the LAN-direct path before Firebase. Defaults on.
  Future<bool> getPreferLocalNetwork() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPreferLocalNetwork) ?? true;
  }

  Future<void> setPreferLocalNetwork(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreferLocalNetwork, enabled);
  }

  Future<bool> getSidebarCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kSidebarCollapsed) ?? false;
  }

  Future<void> setSidebarCollapsed(bool collapsed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSidebarCollapsed, collapsed);
  }

  Future<bool> getRightPanelCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kRightPanelCollapsed) ?? false;
  }

  Future<void> setRightPanelCollapsed(bool collapsed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRightPanelCollapsed, collapsed);
  }

  Future<String> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kThemeMode) ?? 'system';
  }

  Future<void> setThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode);
  }

  Future<String> getHost() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHost) ?? defaultHost;
  }

  Future<void> setHost(String host) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHost, host);
  }

  /// Active LLM provider id (see `LlmProviderKind.id`).
  Future<String> getLlmProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLlmProvider) ?? 'ollama';
  }

  Future<void> setLlmProvider(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLlmProvider, id);
  }

  /// Base URL of a custom OpenAI-compatible server (LM Studio, OpenRouter…).
  Future<String> getCompatBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kCompatBaseUrl) ?? '';
  }

  Future<void> setCompatBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCompatBaseUrl, url.trim());
  }

  // Each provider remembers its own selected model. Ollama keeps the legacy
  // 'default_model' key so existing installs don't lose their choice.
  String _modelKey(String providerId) =>
      providerId == 'ollama' ? _kModel : 'llm_model_$providerId';

  Future<String?> getModelFor(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modelKey(providerId));
  }

  Future<void> setModelFor(String providerId, String? model) async {
    final prefs = await SharedPreferences.getInstance();
    if (model == null) {
      await prefs.remove(_modelKey(providerId));
    } else {
      await prefs.setString(_modelKey(providerId), model);
    }
  }

  Future<double> getTemperature() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_kTemperature) ?? 0.7;
  }

  Future<void> setTemperature(double t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTemperature, t);
  }

  Future<List<Workflow>> loadWorkflows() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kWorkflows);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Workflow.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWorkflows(List<Workflow> workflows) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(workflows.map((w) => w.toJson()).toList());
    await prefs.setString(_kWorkflows, encoded);
  }

  /// Duplicate Finder filter preferences, stored as a single JSON blob.
  Future<Map<String, dynamic>> getDuplicateFinderPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDupFinderPrefs);
    if (raw == null || raw.isEmpty) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  Future<void> setDuplicateFinderPrefs(Map<String, dynamic> prefs) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(_kDupFinderPrefs, jsonEncode(prefs));
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/workflow.dart';

class SettingsStore {
  static const _kHost = 'ollama_host';
  static const _kModel = 'default_model';
  static const _kTemperature = 'temperature';
  static const _kWorkflows = 'workflows_json';
  static const _kThemeMode = 'theme_mode';
  static const _kDupFinderPrefs = 'duplicate_finder_prefs';

  static const String defaultHost = 'http://localhost:11434';

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

  Future<String?> getModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kModel);
  }

  Future<void> setModel(String? model) async {
    final prefs = await SharedPreferences.getInstance();
    if (model == null) {
      await prefs.remove(_kModel);
    } else {
      await prefs.setString(_kModel, model);
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

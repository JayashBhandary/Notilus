import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import '../services/file_service.dart';

enum SortField { name, kind, modified, size }

enum ViewMode { icons, list }

class BrowserProvider extends ChangeNotifier {
  BrowserProvider(this._fileService);

  final FileService _fileService;

  String _currentPath = '';
  List<FileEntry> _entries = [];
  final Set<String> _selectedPaths = {};
  Map<String, String?> _shortcuts = {};
  List<DriveEntry> _drives = const [];
  bool _loading = false;
  String? _error;

  // View state
  SortField _sortField = SortField.name;
  bool _sortAscending = true;
  bool _useGroups = false;
  double _rowDensity = 1.0; // 0.85=compact, 1.0=normal, 1.2=spacious
  ViewMode _viewMode = ViewMode.icons;

  String get currentPath => _currentPath;
  List<FileEntry> get entries => _sortedEntries();
  Set<String> get selectedPaths => _selectedPaths;
  Map<String, String?> get shortcuts => _shortcuts;
  List<DriveEntry> get drives => _drives;
  bool get loading => _loading;
  String? get error => _error;
  SortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  bool get useGroups => _useGroups;
  double get rowDensity => _rowDensity;
  ViewMode get viewMode => _viewMode;

  FileEntry? get primarySelection {
    if (_selectedPaths.isEmpty) return null;
    final path = _selectedPaths.first;
    for (final e in _entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  Future<void> init() async {
    _shortcuts = await _fileService.shortcuts();
    _drives = await _fileService.drives();
    final home = _shortcuts['Home'];
    if (home != null) {
      await navigateTo(home);
    } else {
      notifyListeners();
    }
  }

  Future<void> refreshDrives() async {
    _drives = await _fileService.drives();
    notifyListeners();
  }

  Future<void> navigateTo(String path) async {
    _currentPath = path;
    _selectedPaths.clear();
    _loading = true;
    _error = null;
    notifyListeners();
    final result = await _fileService.listDirectory(path);
    _entries = result.entries;
    _error = result.error;
    _loading = false;
    notifyListeners();
  }

  void toggleSelect(FileEntry entry, {bool additive = false}) {
    if (!additive) _selectedPaths.clear();
    if (_selectedPaths.contains(entry.path)) {
      _selectedPaths.remove(entry.path);
    } else {
      _selectedPaths.add(entry.path);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedPaths.clear();
    notifyListeners();
  }

  Future<void> refresh() async {
    await navigateTo(_currentPath);
  }

  Future<String?> createFolder({String name = 'untitled folder'}) async {
    if (_currentPath.isEmpty) return null;
    final created = await _fileService.createDirectory(_currentPath, name);
    if (created != null) {
      await refresh();
      _selectedPaths
        ..clear()
        ..add(created);
      notifyListeners();
    }
    return created;
  }

  void setSort(SortField field) {
    if (_sortField == field) {
      _sortAscending = !_sortAscending;
    } else {
      _sortField = field;
      _sortAscending = true;
    }
    notifyListeners();
  }

  void setUseGroups(bool value) {
    _useGroups = value;
    notifyListeners();
  }

  void setRowDensity(double value) {
    _rowDensity = value.clamp(0.8, 1.4);
    notifyListeners();
  }

  void setViewMode(ViewMode mode) {
    _viewMode = mode;
    notifyListeners();
  }

  /// Returns entries grouped by kind when [useGroups] is on; otherwise a
  /// single bucket. Each bucket is sorted by the active [sortField].
  List<EntryGroup> groupedEntries() {
    final sorted = _sortedEntries();
    if (!_useGroups) {
      return [EntryGroup(label: null, entries: sorted)];
    }
    final folders = <FileEntry>[];
    final byKind = <String, List<FileEntry>>{};
    for (final e in sorted) {
      if (e.isDirectory) {
        folders.add(e);
        continue;
      }
      final kind = _kindLabel(e);
      byKind.putIfAbsent(kind, () => []).add(e);
    }
    final groups = <EntryGroup>[];
    if (folders.isNotEmpty) {
      groups.add(EntryGroup(label: 'Folders', entries: folders));
    }
    final kinds = byKind.keys.toList()..sort();
    for (final k in kinds) {
      groups.add(EntryGroup(label: k, entries: byKind[k]!));
    }
    return groups;
  }

  List<FileEntry> _sortedEntries() {
    final list = List<FileEntry>.from(_entries);
    int cmp(FileEntry a, FileEntry b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      int r;
      switch (_sortField) {
        case SortField.name:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case SortField.kind:
          r = _kindLabel(a).compareTo(_kindLabel(b));
          if (r == 0) {
            r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }
          break;
        case SortField.modified:
          r = a.modified.compareTo(b.modified);
          break;
        case SortField.size:
          r = a.size.compareTo(b.size);
          break;
      }
      return _sortAscending ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  String _kindLabel(FileEntry e) {
    if (e.isDirectory) return 'Folder';
    final ext = p.extension(e.name).toLowerCase();
    if (ext.isEmpty) return 'Document';
    return '${ext.substring(1).toUpperCase()} file';
  }
}

class EntryGroup {
  EntryGroup({required this.label, required this.entries});
  final String? label;
  final List<FileEntry> entries;
}

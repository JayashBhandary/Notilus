import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/file_entry.dart';
import '../models/media_kind.dart';
import '../services/file_service.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';

enum SortField { name, kind, modified, size }

enum ViewMode { icons, list }

/// Which page occupies the app's central content pane. Non-file pages
/// (System Overview, Duplicate Finder, the media libraries) render here
/// instead of pushing a full-screen route; navigating to any folder returns
/// to [files].
enum CenterView {
  files,
  systemOverview,
  duplicates,
  transfers,
  sharing,
  mediaImages,
  mediaVideos,
  mediaDocuments,
}

extension CenterViewMedia on CenterView {
  /// The media library this view shows, or null for the non-media pages.
  MediaKind? get mediaKind {
    switch (this) {
      case CenterView.mediaImages:
        return MediaKind.images;
      case CenterView.mediaVideos:
        return MediaKind.videos;
      case CenterView.mediaDocuments:
        return MediaKind.documents;
      case CenterView.files:
      case CenterView.systemOverview:
      case CenterView.duplicates:
      case CenterView.transfers:
      case CenterView.sharing:
        return null;
    }
  }
}

/// The center view that shows [kind].
CenterView centerViewForMedia(MediaKind kind) {
  switch (kind) {
    case MediaKind.images:
      return CenterView.mediaImages;
    case MediaKind.videos:
      return CenterView.mediaVideos;
    case MediaKind.documents:
      return CenterView.mediaDocuments;
  }
}

class BrowserProvider extends ChangeNotifier {
  BrowserProvider(this._fileService);

  final FileService _fileService;

  String _currentPath = '';
  List<FileEntry> _entries = [];
  final Set<String> _selectedPaths = {};
  // Anchor for Shift range-selection: the item a range extends *from*. Set by
  // a plain/Cmd click, held steady across successive Shift-clicks.
  String? _anchorPath;
  Map<String, String?> _shortcuts = {};
  List<DriveEntry> _drives = const [];
  bool _loading = false;
  String? _error;

  // Navigation history. _back is most-recently-visited-first.
  final List<String> _back = [];
  final List<String> _forward = [];

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  // Filesystem watcher for the current folder. We debounce listings since a
  // single file save can fire multiple events.
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _watchDebounce;

  // View state
  SortField _sortField = SortField.name;
  bool _sortAscending = true;
  bool _useGroups = false;
  double _rowDensity = 1.0; // 0.85=compact, 1.0=normal, 1.2=spacious

  /// Extra thumbnail scale for icon view only, on top of [rowDensity]. Row
  /// density has to stay near 1.0 to keep list rows readable, so it can't also
  /// be the knob for "show me big previews" in the grid.
  double _gridIconScale = 1.0;
  ViewMode _viewMode = ViewMode.icons;
  CenterView _centerView = CenterView.files;
  bool _showHidden = false;

  // Derived-view caches. Sorting and grouping are pure functions of
  // (_entries, _sortField, _sortAscending, _useGroups), but `entries` is read
  // from build methods — without memoisation a single notifyListeners() costs
  // several full sorts of the folder. Invalidated by [_invalidateView].
  List<FileEntry>? _sortedCache;
  List<EntryGroup>? _groupedCache;

  void _invalidateView() {
    _sortedCache = null;
    _groupedCache = null;
  }

  String get currentPath => _currentPath;
  List<FileEntry> get entries => _sortedEntries();

  /// Number of entries in the current folder. Order-independent, so it reads
  /// the raw list — callers that only need a count shouldn't force a sort.
  int get entryCount => _entries.length;
  Set<String> get selectedPaths => _selectedPaths;
  Map<String, String?> get shortcuts => _shortcuts;
  List<DriveEntry> get drives => _drives;
  bool get loading => _loading;
  String? get error => _error;
  SortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  bool get useGroups => _useGroups;
  double get rowDensity => _rowDensity;
  double get gridIconScale => _gridIconScale;
  ViewMode get viewMode => _viewMode;
  CenterView get centerView => _centerView;
  bool get showHidden => _showHidden;

  /// Shows or hides dot-prefixed entries. Requires a re-listing: the filter is
  /// applied natively during the directory read, not on the result.
  Future<void> setShowHidden(bool value) async {
    if (_showHidden == value) return;
    _showHidden = value;
    if (_currentPath.isNotEmpty) await _load(_currentPath);
  }

  /// Switches the central content pane to a non-file page. File navigation
  /// implicitly returns to [CenterView.files] via [_load].
  void showCenterView(CenterView view) {
    if (_centerView == view) return;
    _centerView = view;
    notifyListeners();
  }

  FileEntry? get primarySelection {
    if (_selectedPaths.isEmpty) return null;
    final path = _selectedPaths.first;
    for (final e in _entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  Future<void> init() async {
    // Remote sources are part of the sidebar's "Locations" list, so they have
    // to be loaded before the first frame that draws it.
    await RemoteHub.instance.load();
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
    if (path == _currentPath) {
      await _load(path);
      return;
    }
    if (_currentPath.isNotEmpty) {
      _back.add(_currentPath);
    }
    _forward.clear();
    await _load(path);
  }

  Future<void> goBack() async {
    if (_back.isEmpty) return;
    final target = _back.removeLast();
    if (_currentPath.isNotEmpty) _forward.add(_currentPath);
    await _load(target);
  }

  /// True when the current folder has a parent to go up to.
  bool get canGoUp {
    if (_currentPath.isEmpty) return false;
    final parent = VPath.dirname(_currentPath);
    return parent != _currentPath && parent.isNotEmpty;
  }

  /// True when the folder on screen lives on a mounted remote source. Callers
  /// use it to hide actions that only a local file can answer — "Reveal in
  /// Finder", the integrated terminal's working directory, image transforms
  /// that the Rust core runs against a real path.
  bool get isRemote => VPath.isRemote(_currentPath);

  /// The remote source the current folder belongs to, or null when local.
  String? get remoteConnectionId => VPath.connectionOf(_currentPath);

  /// Navigates to the parent folder, recording the move in history so Back
  /// returns here.
  Future<void> goUp() async {
    if (!canGoUp) return;
    await navigateTo(VPath.dirname(_currentPath));
  }

  Future<void> goForward() async {
    if (_forward.isEmpty) return;
    final target = _forward.removeLast();
    if (_currentPath.isNotEmpty) _back.add(_currentPath);
    await _load(target);
  }

  Future<void> _load(String path) async {
    // Any folder navigation brings the file browser back to the center pane.
    _centerView = CenterView.files;
    _currentPath = path;
    _selectedPaths.clear();
    _anchorPath = null;
    _loading = true;
    _error = null;
    notifyListeners();
    final result =
        await _fileService.listDirectory(path, showHidden: _showHidden);
    _entries = result.entries;
    _invalidateView();
    _error = result.error;
    _loading = false;
    notifyListeners();
    _startWatching(path);
  }

  void _startWatching(String path) {
    _stopWatching();
    if (path.isEmpty) return;
    // Cloud sources have nothing to watch: there is no inotify over HTTP, and
    // polling every folder the user visits would burn quota for a change they
    // can pick up with a refresh.
    if (VPath.isRemote(path)) return;
    try {
      // Directory.watch isn't supported on every platform/filesystem; if it
      // throws we just skip auto-refresh and rely on manual navigation.
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      _watchSub = dir.watch(recursive: false).listen(
            (_) => _scheduleSilentReload(),
            onError: (_) {},
            cancelOnError: false,
          );
    } catch (_) {
      // No-op: watching isn't critical.
    }
  }

  void _stopWatching() {
    _watchSub?.cancel();
    _watchSub = null;
    _watchDebounce?.cancel();
    _watchDebounce = null;
  }

  void _scheduleSilentReload() {
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 180), _silentReload);
  }

  Future<void> _silentReload() async {
    if (_currentPath.isEmpty) return;
    final result =
        await _fileService.listDirectory(_currentPath, showHidden: _showHidden);
    _entries = result.entries;
    _invalidateView();
    _error = result.error;
    // Drop any selections that no longer exist. Build a path set first: a
    // linear indexWhere per selected path would be O(selected × entries),
    // which a Cmd+A on a large folder turns into millions of comparisons on
    // every filesystem-watch event.
    final live = {for (final e in _entries) e.path};
    _selectedPaths.removeWhere((path) => !live.contains(path));
    if (_anchorPath != null && !live.contains(_anchorPath)) _anchorPath = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }

  void toggleSelect(FileEntry entry, {bool additive = false}) {
    if (!additive) _selectedPaths.clear();
    if (_selectedPaths.contains(entry.path)) {
      _selectedPaths.remove(entry.path);
    } else {
      _selectedPaths.add(entry.path);
    }
    _anchorPath = entry.path;
    notifyListeners();
  }

  /// Shift-click range selection: replaces the selection with the contiguous
  /// run — in the currently displayed order — between the anchor and [entry].
  /// The anchor is left untouched so repeated Shift-clicks pivot from the same
  /// origin. With no prior anchor, [entry] becomes both anchor and selection.
  void selectRange(FileEntry entry) {
    final order = _flatVisibleOrder();
    final bi = order.indexWhere((e) => e.path == entry.path);
    if (bi < 0) return;
    var ai = _anchorPath == null
        ? -1
        : order.indexWhere((e) => e.path == _anchorPath);
    if (ai < 0) {
      _anchorPath = entry.path;
      ai = bi;
    }
    final lo = ai <= bi ? ai : bi;
    final hi = ai <= bi ? bi : ai;
    _selectedPaths
      ..clear()
      ..addAll([for (var i = lo; i <= hi; i++) order[i].path]);
    notifyListeners();
  }

  /// Selects every entry in the current folder (Cmd/Ctrl+A). Anchors on the
  /// first visible item so a following Shift-click extends from the top.
  void selectAll() {
    final order = _flatVisibleOrder();
    if (order.isEmpty) return;
    _selectedPaths
      ..clear()
      ..addAll(order.map((e) => e.path));
    _anchorPath = order.first.path;
    notifyListeners();
  }

  /// Replaces the selection wholesale (used by rubber-band / marquee drags).
  /// No-ops when the set is unchanged so live drags don't spam rebuilds. The
  /// anchor is intentionally preserved.
  void replaceSelection(Set<String> paths) {
    if (_selectedPaths.length == paths.length &&
        _selectedPaths.containsAll(paths)) {
      return;
    }
    _selectedPaths
      ..clear()
      ..addAll(paths);
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedPaths.isEmpty && _anchorPath == null) return;
    _selectedPaths.clear();
    _anchorPath = null;
    notifyListeners();
  }

  /// The entries in the exact order they appear on screen (grouping applied,
  /// each group sorted). Range selection walks this so Shift-select matches
  /// what the user sees.
  List<FileEntry> _flatVisibleOrder() {
    final out = <FileEntry>[];
    for (final g in groupedEntries()) {
      out.addAll(g.entries);
    }
    return out;
  }

  Future<void> refresh() async {
    await navigateTo(_currentPath);
  }

  /// Navigates to the folder containing [path] and selects the item there.
  ///
  /// This is what makes a search result actionable: the user lands on the file
  /// in context, with the rest of its folder around it, rather than on a
  /// detached result.
  Future<void> revealPath(String path) async {
    final parent = VPath.dirname(path);
    if (parent != _currentPath) {
      await navigateTo(parent);
    }
    _selectedPaths
      ..clear()
      ..add(path);
    _anchorPath = path;
    notifyListeners();
  }

  Future<String?> createFolder({String name = 'untitled folder'}) async {
    if (_currentPath.isEmpty) return null;
    final created = await _fileService.createDirectory(_currentPath, name);
    if (created != null) {
      await refresh();
      _selectedPaths
        ..clear()
        ..add(created);
      _anchorPath = created;
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
    _invalidateView();
    notifyListeners();
  }

  void setUseGroups(bool value) {
    if (_useGroups == value) return;
    _useGroups = value;
    _invalidateView();
    notifyListeners();
  }

  void setRowDensity(double value) {
    _rowDensity = value.clamp(0.8, 1.4);
    notifyListeners();
  }

  void setGridIconScale(double value) {
    final next = value.clamp(1.0, 4.0);
    if (next == _gridIconScale) return;
    _gridIconScale = next;
    notifyListeners();
  }

  void setViewMode(ViewMode mode) {
    _viewMode = mode;
    notifyListeners();
  }

  /// Returns entries grouped by kind when [useGroups] is on; otherwise a
  /// single bucket. Each bucket is sorted by the active [sortField].
  List<EntryGroup> groupedEntries() => _groupedCache ??= _computeGroups();

  List<EntryGroup> _computeGroups() {
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

  List<FileEntry> _sortedEntries() => _sortedCache ??= _computeSorted();

  List<FileEntry> _computeSorted() {
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
    final ext = VPath.extension(e.name).toLowerCase();
    if (ext.isEmpty) return 'Document';
    return '${ext.substring(1).toUpperCase()} file';
  }
}

class EntryGroup {
  EntryGroup({required this.label, required this.entries});
  final String? label;
  final List<FileEntry> entries;
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/file_entry.dart';
import '../models/media_kind.dart';
import '../services/file_service.dart';
import '../services/native_core.dart';
import '../services/settings_store.dart';

/// What the media pages order by. Distinct from `BrowserProvider.SortField`:
/// media has no "kind" axis (every entry is the same kind by construction) and
/// its date axis is the only one users reach for first.
enum MediaSortField { name, date, size }

/// How the listing is bucketed. `all` is a single flat run.
enum MediaGroupMode { all, year, month }

enum MediaViewMode { grid, list }

/// One bucket of the grouped listing. A `null` label means "no header" — the
/// flat [MediaGroupMode.all] case.
class MediaGroup {
  const MediaGroup({required this.label, required this.entries});
  final String? label;
  final List<FileEntry> entries;
}

const List<String> _kMonthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Per-kind scan results and view state.
///
/// Widgets read this; only [MediaProvider] mutates it (the private setters are
/// reachable because both classes live in this library).
class MediaKindState {
  MediaKindState(this.kind)
      : _viewMode = kind == MediaKind.documents
            ? MediaViewMode.list
            : MediaViewMode.grid;

  final MediaKind kind;

  List<FileEntry> _entries = const [];
  bool _scanning = false;
  bool _scanned = false;
  String? _error;
  int _filesScanned = 0;
  bool _truncated = false;

  String _query = '';
  // Newest-first is the useful default for media: the photos you just took are
  // the ones you are looking for.
  MediaSortField _sortField = MediaSortField.date;
  bool _ascending = false;
  MediaGroupMode _groupMode = MediaGroupMode.all;
  MediaViewMode _viewMode;

  /// Grid only. Off turns the tiles into a plain wall of square thumbnails —
  /// the list view is nothing but labels, so it ignores this.
  bool _showLabels = true;

  bool _selecting = false;
  final Set<String> _selected = {};

  // Scan plumbing.
  String? _opId;
  StreamSubscription<SearchEvent>? _sub;
  Timer? _flush;

  // Derived-view caches: `visible` and `groups` are read from build methods, so
  // without memoisation a single notifyListeners() re-sorts the whole library.
  List<FileEntry>? _visibleCache;
  List<MediaGroup>? _groupCache;

  bool get scanning => _scanning;
  bool get scanned => _scanned;
  String? get error => _error;
  int get filesScanned => _filesScanned;

  /// True when the scan stopped at the result cap, so the page is showing a
  /// prefix of the library rather than all of it.
  bool get truncated => _truncated;

  String get query => _query;
  MediaSortField get sortField => _sortField;
  bool get ascending => _ascending;
  MediaGroupMode get groupMode => _groupMode;
  MediaViewMode get viewMode => _viewMode;
  bool get showLabels => _showLabels;
  bool get selecting => _selecting;
  Set<String> get selected => _selected;

  /// Everything found, before the search filter.
  int get totalCount => _entries.length;

  /// Post-filter, sorted listing.
  List<FileEntry> get visible => _visibleCache ??= _computeVisible();
  int get visibleCount => visible.length;

  bool get isFiltered => _query.trim().isNotEmpty;

  List<MediaGroup> get groups => _groupCache ??= _computeGroups();

  void _invalidate() {
    _visibleCache = null;
    _groupCache = null;
  }

  List<FileEntry> _computeVisible() {
    final needle = _query.trim().toLowerCase();
    final list = needle.isEmpty
        ? List<FileEntry>.from(_entries)
        : [
            for (final e in _entries)
              if (e.name.toLowerCase().contains(needle)) e,
          ];

    int cmp(FileEntry a, FileEntry b) {
      int r;
      switch (_sortField) {
        case MediaSortField.name:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case MediaSortField.date:
          r = a.modified.compareTo(b.modified);
        case MediaSortField.size:
          r = a.size.compareTo(b.size);
      }
      if (r == 0) r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (r == 0) r = a.path.compareTo(b.path);
      return _ascending ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  List<MediaGroup> _computeGroups() {
    final list = visible;
    if (_groupMode == MediaGroupMode.all) {
      return [MediaGroup(label: null, entries: list)];
    }

    // Keyed numerically (year, or year*100+month) so groups can be ordered
    // without parsing their labels back.
    final buckets = <int, List<FileEntry>>{};
    for (final e in list) {
      final d = e.modified;
      final key = _groupMode == MediaGroupMode.year
          ? d.year
          : d.year * 100 + d.month;
      buckets.putIfAbsent(key, () => []).add(e);
    }

    // Group order follows the sort direction even when sorting by name or
    // size — one direction control for the whole page reads better than a
    // second, separate one just for the headers.
    final keys = buckets.keys.toList()
      ..sort((a, b) => _ascending ? a.compareTo(b) : b.compareTo(a));

    return [
      for (final key in keys)
        MediaGroup(label: _labelFor(key), entries: buckets[key]!),
    ];
  }

  String _labelFor(int key) {
    if (_groupMode == MediaGroupMode.year) return '$key';
    final year = key ~/ 100;
    final month = key % 100;
    final name = (month >= 1 && month <= 12) ? _kMonthNames[month - 1] : '?';
    return '$name $year';
  }

  void _setEntries(List<FileEntry> entries) {
    _entries = entries;
    _invalidate();
  }
}

/// Scans the user's configured folders for images, videos and documents, and
/// owns the per-kind view state behind the Media pages.
///
/// The walk itself is the Rust searcher: an empty query with an extension
/// allow-list means "every file of these types", which is exactly a media
/// library scan, so nothing new had to cross the bridge. Results are cached per
/// kind for the session — a rescan is explicit, or implied by changing roots.
class MediaProvider extends ChangeNotifier {
  MediaProvider({
    FileService? fileService,
    SettingsStore? store,
    NativeCore? core,
  })  : _fileService = fileService ?? FileService(),
        _store = store ?? SettingsStore(),
        _core = core ?? NativeCore.instance;

  final FileService _fileService;
  final SettingsStore _store;
  final NativeCore _core;

  /// Cap per scan. High enough that a normal library arrives whole, low enough
  /// that a root like `/` can't stream the UI to death.
  static const int _maxResults = 20000;

  /// Directory basenames pruned during the walk (lowercase, matched by the
  /// Rust side). These hold app caches and dependency trees whose thumbnails
  /// and bundled PDFs would otherwise swamp a user's own media.
  static const List<String> _prunedDirs = [
    'node_modules', '.git', '.cache', 'cache', 'caches', 'library',
    'appdata', '.local', '.config', '.venv', 'venv', 'build', 'target',
    '.trash', '.gradle', '.pub-cache', '.cargo', '.rustup', 'pods',
  ];

  final Map<MediaKind, MediaKindState> _states = {
    for (final kind in MediaKind.values) kind: MediaKindState(kind),
  };

  List<String> _roots = const [];
  bool _ready = false;
  Future<void>? _initFuture;

  String? _homePath;
  String? _desktopPath;
  String? _documentsPath;

  MediaKindState state(MediaKind kind) => _states[kind]!;

  List<String> get roots => _roots;

  /// False until the stored roots have been read; the pages show a spinner
  /// rather than a misleading "no folders configured" in that window.
  bool get ready => _ready;

  /// Where a compressed archive lands. Desktop where there is one; mobile has
  /// no Desktop, so it falls back to the app's Documents folder.
  String? get archiveDestination =>
      _desktopPath ?? _documentsPath ?? _homePath;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    final shortcuts = await _fileService.shortcuts();
    _homePath = shortcuts['Home'];
    _desktopPath = shortcuts['Desktop'];
    _documentsPath = shortcuts['Documents'];

    final stored = await _store.getMediaRoots();
    _roots = stored.isNotEmpty
        ? List.unmodifiable(stored)
        : List.unmodifiable([if (_homePath != null) _homePath!]);
    _ready = true;
    notifyListeners();
  }

  Future<void> addRoot(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || _roots.contains(trimmed)) return;
    _roots = List.unmodifiable([..._roots, trimmed]);
    await _store.setMediaRoots(_roots);
    _invalidateAllScans();
    notifyListeners();
  }

  Future<void> removeRoot(String path) async {
    if (!_roots.contains(path)) return;
    _roots = List.unmodifiable([
      for (final r in _roots)
        if (r != path) r,
    ]);
    await _store.setMediaRoots(_roots);
    _invalidateAllScans();
    notifyListeners();
  }

  /// Scans [kind] unless it already has results or a scan in flight. Safe to
  /// call on every page build.
  Future<void> ensureScanned(MediaKind kind) async {
    await init();
    final st = state(kind);
    if (st._scanned || st._scanning) return;
    await _scan(kind);
  }

  /// Re-walks the roots for [kind], discarding what's cached.
  Future<void> rescan(MediaKind kind) async {
    await init();
    await _scan(kind);
  }

  Future<void> _scan(MediaKind kind) async {
    final st = state(kind);
    _stopScan(st);

    if (_roots.isEmpty) {
      st
        .._scanning = false
        .._scanned = true
        .._error = null
        .._truncated = false
        .._setEntries(const []);
      st._selected.clear();
      notifyListeners();
      return;
    }

    final opId = _core.newOpId();
    st
      .._opId = opId
      .._scanning = true
      .._scanned = false
      .._error = null
      .._filesScanned = 0
      .._truncated = false
      .._setEntries(const []);
    st._selected.clear();
    notifyListeners();

    // Hits are buffered and published on a timer: a library scan produces them
    // far faster than the grid can usefully rebuild.
    final buffer = <FileEntry>[];
    void publish() {
      if (st._opId != opId) return;
      st._setEntries(List.unmodifiable(buffer));
      notifyListeners();
    }

    final request = SearchRequest(
      roots: List.of(_roots),
      // Empty query means "match every file"; the extension allow-list is
      // what turns this into a media scan.
      query: '',
      searchContent: false,
      matchCase: false,
      useWildcards: false,
      maxResults: BigInt.from(_maxResults),
      skipHidden: true,
      excludedDirNames: _prunedDirs,
      allowedExtensions: kind.extensions.toList(),
    );

    try {
      st._sub = _core.search(request: request, opId: opId).listen(
        (event) {
          if (st._opId != opId) return;
          switch (event) {
            case SearchEvent_Hit(:final field0):
              final entry = _toEntry(field0.entry);
              if (entry == null) return;
              buffer.add(entry);
              st._flush ??= Timer(const Duration(milliseconds: 150), () {
                st._flush = null;
                publish();
              });
            case SearchEvent_Done(:final field0):
              st._flush?.cancel();
              st._flush = null;
              st
                .._setEntries(List.unmodifiable([
                  for (final hit in field0.hits)
                    if (_toEntry(hit.entry) case final e?) e,
                ]))
                .._filesScanned = field0.filesScanned.toInt()
                .._truncated = field0.truncated
                .._scanning = false
                .._scanned = true;
              notifyListeners();
          }
        },
        onError: (Object e) {
          if (st._opId != opId) return;
          st
            .._error = '$e'
            .._scanning = false
            .._scanned = true;
          notifyListeners();
        },
        onDone: () {
          if (st._opId != opId) return;
          st._flush?.cancel();
          st._flush = null;
          if (st._scanning) {
            st
              .._scanning = false
              .._scanned = true;
            notifyListeners();
          }
        },
      );
    } catch (e) {
      st
        .._error = '$e'
        .._scanning = false
        .._scanned = true;
      notifyListeners();
    }
  }

  /// Stops an in-flight scan for [kind] and keeps whatever arrived so far.
  void cancelScan(MediaKind kind) {
    final st = state(kind);
    if (!st._scanning) return;
    _stopScan(st);
    st
      .._scanning = false
      .._scanned = true;
    notifyListeners();
  }

  void _stopScan(MediaKindState st) {
    final opId = st._opId;
    st._opId = null;
    st._flush?.cancel();
    st._flush = null;
    st._sub?.cancel();
    st._sub = null;
    if (opId != null) {
      // Fire and forget: Rust only flips a flag, and cancelling a finished run
      // returns false harmlessly.
      unawaited(_core.cancel(opId));
    }
  }

  void _invalidateAllScans() {
    for (final st in _states.values) {
      _stopScan(st);
      st
        .._scanning = false
        .._scanned = false
        .._error = null
        .._filesScanned = 0
        .._truncated = false
        .._setEntries(const []);
      st._selected.clear();
    }
  }

  FileEntry? _toEntry(DirEntryInfo info) {
    if (info.isDir) return null;
    return FileEntry(
      path: info.path,
      name: info.name,
      isDirectory: false,
      size: info.size.toInt(),
      modified: DateTime.fromMillisecondsSinceEpoch(info.modifiedMs.toInt()),
    );
  }

  // ── view controls ────────────────────────────────────────────────────────

  void setQuery(MediaKind kind, String value) {
    final st = state(kind);
    if (st._query == value) return;
    st._query = value;
    st._invalidate();
    notifyListeners();
  }

  /// Picking the active field again flips the direction, matching the file
  /// browser's column headers.
  void setSortField(MediaKind kind, MediaSortField field) {
    final st = state(kind);
    if (st._sortField == field) {
      st._ascending = !st._ascending;
    } else {
      st._sortField = field;
      // Dates and sizes default to largest/newest first; names to A→Z.
      st._ascending = field == MediaSortField.name;
    }
    st._invalidate();
    notifyListeners();
  }

  void toggleSortDirection(MediaKind kind) {
    final st = state(kind);
    st._ascending = !st._ascending;
    st._invalidate();
    notifyListeners();
  }

  void setGroupMode(MediaKind kind, MediaGroupMode mode) {
    final st = state(kind);
    if (st._groupMode == mode) return;
    st._groupMode = mode;
    st._invalidate();
    notifyListeners();
  }

  void setViewMode(MediaKind kind, MediaViewMode mode) {
    final st = state(kind);
    if (st._viewMode == mode) return;
    st._viewMode = mode;
    notifyListeners();
  }

  /// Shows or hides the name and date under each grid tile.
  void setShowLabels(MediaKind kind, bool value) {
    final st = state(kind);
    if (st._showLabels == value) return;
    st._showLabels = value;
    notifyListeners();
  }

  void toggleLabels(MediaKind kind) =>
      setShowLabels(kind, !state(kind)._showLabels);

  // ── selection ────────────────────────────────────────────────────────────

  void setSelecting(MediaKind kind, bool value) {
    final st = state(kind);
    if (st._selecting == value) return;
    st._selecting = value;
    if (!value) st._selected.clear();
    notifyListeners();
  }

  void toggleSelect(MediaKind kind, String path) {
    final st = state(kind);
    if (!st._selected.remove(path)) st._selected.add(path);
    notifyListeners();
  }

  /// Selects everything currently visible — the filtered set, not the whole
  /// library, so "Select all" can't quietly act on hidden entries.
  void selectAllVisible(MediaKind kind) {
    final st = state(kind);
    st._selected
      ..clear()
      ..addAll(st.visible.map((e) => e.path));
    notifyListeners();
  }

  void clearSelection(MediaKind kind) {
    final st = state(kind);
    if (st._selected.isEmpty) return;
    st._selected.clear();
    notifyListeners();
  }

  /// Drops [paths] from the cached listing after they've been trashed or moved
  /// away, so the page updates without paying for a full rescan.
  void removePaths(MediaKind kind, Iterable<String> paths) {
    final gone = paths.toSet();
    if (gone.isEmpty) return;
    final st = state(kind);
    st._setEntries(List.unmodifiable([
      for (final e in st._entries)
        if (!gone.contains(e.path)) e,
    ]));
    st._selected.removeAll(gone);
    notifyListeners();
  }

  /// Test hook: installs a listing without touching the filesystem.
  @visibleForTesting
  void seedEntries(MediaKind kind, List<FileEntry> entries) {
    final st = state(kind);
    st
      .._setEntries(List.unmodifiable(entries))
      .._scanned = true
      .._scanning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final st in _states.values) {
      _stopScan(st);
    }
    super.dispose();
  }
}

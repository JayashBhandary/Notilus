import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/native_core.dart';
import '../services/remote/remote_file_system.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';

/// Drives filename and content search over the current folder subtree.
///
/// The app had no search at all before this. Everything expensive — the
/// parallel walk, the SIMD substring scan over file contents — happens in the
/// Rust core; this class debounces keystrokes, streams hits in as they arrive,
/// and cancels the previous run when the query changes.
class SearchProvider extends ChangeNotifier {
  SearchProvider({NativeCore? core}) : _core = core ?? NativeCore.instance;

  final NativeCore _core;

  /// Long enough that typing a word doesn't launch a walk per keystroke,
  /// short enough to still feel live.
  static const _debounce = Duration(milliseconds: 220);

  Timer? _debounceTimer;
  StreamSubscription<SearchEvent>? _subscription;
  StreamSubscription<RemoteEntry>? _remoteSubscription;
  String? _activeOpId;
  int _remoteRun = 0;

  String _query = '';
  String _root = '';
  bool _searchContent = false;
  bool _running = false;
  bool _truncated = false;
  int _filesScanned = 0;
  List<SearchHit> _hits = const [];

  String get query => _query;
  bool get searchContent => _searchContent;
  bool get isRunning => _running;
  bool get isActive => _query.isNotEmpty;
  bool get truncated => _truncated;
  int get filesScanned => _filesScanned;
  List<SearchHit> get hits => _hits;

  /// True while the results come from a cloud source, where matching is by
  /// name only — content search would mean downloading the folder.
  bool get isRemoteSearch => VPath.isRemote(_root);

  /// Updates the query and schedules a run. Safe to call on every keystroke.
  void setQuery(String value, {required String root}) {
    _query = value;
    _root = root;
    _debounceTimer?.cancel();

    if (value.trim().isEmpty) {
      _cancelActive();
      _hits = const [];
      _truncated = false;
      _filesScanned = 0;
      _running = false;
      notifyListeners();
      return;
    }

    notifyListeners();
    _debounceTimer = Timer(_debounce, _start);
  }

  /// Toggles content search. Re-runs immediately — the user flipped this
  /// deliberately, so there's nothing to debounce.
  void setSearchContent(bool value) {
    if (_searchContent == value) return;
    _searchContent = value;
    if (_query.trim().isNotEmpty) _start();
    notifyListeners();
  }

  /// Clears the query and stops any run in flight.
  void clear() {
    _debounceTimer?.cancel();
    _cancelActive();
    _query = '';
    _hits = const [];
    _truncated = false;
    _filesScanned = 0;
    _running = false;
    notifyListeners();
  }

  Future<void> _start() async {
    if (_root.isEmpty) return;
    _cancelActive();
    if (VPath.isRemote(_root)) {
      await _startRemote();
      return;
    }

    final opId = _core.newOpId();
    _activeOpId = opId;
    _running = true;
    _hits = const [];
    _truncated = false;
    _filesScanned = 0;
    notifyListeners();

    // Accumulate into a local buffer and publish in batches: a search over a
    // large tree can produce hits faster than the UI can usefully rebuild.
    final buffer = <SearchHit>[];
    Timer? flush;
    void publish() {
      if (_activeOpId != opId) return;
      _hits = List.unmodifiable(buffer);
      notifyListeners();
    }

    final request = SearchRequest(
      roots: [_root],
      query: _query,
      searchContent: _searchContent,
      matchCase: false,
      useWildcards: _query.contains('*'),
      maxResults: BigInt.from(5000),
      skipHidden: true,
      excludedDirNames: const [],
      allowedExtensions: null,
    );

    try {
      _subscription = _core
          .search(request: request, opId: opId)
          .listen((event) {
        switch (event) {
          case SearchEvent_Hit(:final field0):
            buffer.add(field0);
            flush ??= Timer(const Duration(milliseconds: 120), () {
              flush = null;
              publish();
            });
          case SearchEvent_Done(:final field0):
            flush?.cancel();
            flush = null;
            if (_activeOpId != opId) return;
            _hits = List.unmodifiable(field0.hits);
            _truncated = field0.truncated;
            _filesScanned = field0.filesScanned.toInt();
            _running = false;
            notifyListeners();
        }
      }, onError: (_) {
        if (_activeOpId != opId) return;
        _running = false;
        notifyListeners();
      }, onDone: () {
        if (_activeOpId != opId) return;
        _running = false;
        notifyListeners();
      });
    } catch (_) {
      _running = false;
      notifyListeners();
    }
  }

  /// Name search against a mounted cloud source.
  ///
  /// Hits are shaped into the same [SearchHit] the Rust search emits, so the
  /// results list, the reveal-on-tap and the row rendering are all shared —
  /// only where the names come from differs.
  Future<void> _startRemote() async {
    final run = ++_remoteRun;
    _running = true;
    _hits = const [];
    _truncated = false;
    _filesScanned = 0;
    notifyListeners();

    final query = _query;
    final root = _root;
    final RemoteFileSystem? fs;
    try {
      fs = await RemoteHub.instance.fsForPath(root);
    } catch (_) {
      if (run == _remoteRun) {
        _running = false;
        notifyListeners();
      }
      return;
    }
    if (fs == null || run != _remoteRun) return;

    final buffer = <SearchHit>[];
    Timer? flush;
    void publish() {
      if (run != _remoteRun) return;
      _hits = List.unmodifiable(buffer);
      notifyListeners();
    }

    _remoteSubscription = fs.search(root, query).listen(
      (entry) {
        buffer.add(SearchHit(
          entry: DirEntryInfo(
            path: entry.path,
            name: entry.name,
            isDir: entry.isDirectory,
            size: BigInt.from(entry.size),
            modifiedMs: entry.modified.millisecondsSinceEpoch,
          ),
          kind: HitKind.name,
        ));
        flush ??= Timer(const Duration(milliseconds: 120), () {
          flush = null;
          publish();
        });
      },
      onError: (_) {
        flush?.cancel();
        if (run != _remoteRun) return;
        _running = false;
        publish();
        notifyListeners();
      },
      onDone: () {
        flush?.cancel();
        if (run != _remoteRun) return;
        _filesScanned = buffer.length;
        _running = false;
        publish();
        notifyListeners();
      },
      cancelOnError: true,
    );
  }

  void _cancelActive() {
    final opId = _activeOpId;
    _activeOpId = null;
    _remoteRun++;
    _remoteSubscription?.cancel();
    _remoteSubscription = null;
    _subscription?.cancel();
    _subscription = null;
    if (opId != null) {
      // Fire and forget: the Rust side just flips a flag, and a search that
      // already finished returns false harmlessly.
      unawaited(_core.cancel(opId));
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _cancelActive();
    super.dispose();
  }
}

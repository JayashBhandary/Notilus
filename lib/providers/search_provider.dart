import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/native_core.dart';

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
  String? _activeOpId;

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

  void _cancelActive() {
    final opId = _activeOpId;
    _activeOpId = null;
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

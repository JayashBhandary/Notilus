import 'dart:async';

import '../models/file_entry.dart';
import '../src/rust/api/dedupe.dart' as rust;
import 'native_core.dart' as native;

/// A set of files that share identical size and content hash — i.e. true
/// byte-for-byte duplicates.
class DuplicateGroup {
  DuplicateGroup({
    required this.hash,
    required this.size,
    required this.files,
  });

  final String hash;
  final int size;
  final List<FileEntry> files;

  /// Space that could be reclaimed by keeping a single copy.
  int get reclaimableBytes => size * (files.length - 1);

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'size': size,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory DuplicateGroup.fromJson(Map<String, dynamic> json) => DuplicateGroup(
        hash: json['hash'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        files: (json['files'] as List? ?? const [])
            .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Live progress emitted while a scan runs.
class ScanProgress {
  ScanProgress({
    required this.phase,
    required this.filesSeen,
    required this.filesHashed,
    required this.hashTotal,
    this.currentPath = '',
  });

  /// 'Scanning' while walking the tree, 'Comparing' while hashing candidates.
  final String phase;
  final int filesSeen;
  final int filesHashed;
  final int hashTotal;
  final String currentPath;
}

/// Walks one or more root paths and reports groups of duplicate files.
///
/// The crawl, hashing and grouping all happen in the Rust core. The Dart
/// implementation this replaces ran in a spawned isolate — so it never blocked
/// the UI — but it was single-threaded end to end: one directory at a time, one
/// `stat()` per file, and every size-collision candidate read in full.
///
/// The native pipeline walks and hashes in parallel, separates most collisions
/// with a head+tail fingerprint before reading anything whole, and collapses
/// hardlinks (which the path-string de-duplication here used to report as
/// reclaimable when deleting them would free nothing).
///
/// Create a fresh instance per scan; call [cancel] to stop early.
class DuplicateFinderService {
  /// Directory names that almost never hold user files worth de-duplicating
  /// and which balloon scan time. Mirrors `DEFAULT_EXCLUDED_DIRS` in the core.
  static const defaultExcludedDirs = <String>{
    'node_modules', '.git', '.svn', '.hg',
    'venv', '.venv', '__pycache__', 'site-packages',
    '.tox', '.mypy_cache', '.pytest_cache',
    'build', 'dist', 'target', '.gradle', '.dart_tool',
    '.next', '.nuxt', '.parcel-cache',
    'pods', 'carthage', 'deriveddata',
    'vendor', 'bower_components', '.cache', '.terraform', '.cargo',
  };

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  String? _opId;
  StreamSubscription<native.ScanEvent>? _subscription;

  /// Stops an in-flight scan and resolves the pending future with an empty
  /// result. The core polls the flag between files, so this takes effect
  /// promptly rather than after the current root finishes.
  void cancel() {
    _cancelled = true;
    final opId = _opId;
    if (opId != null) unawaited(native.NativeCore.instance.cancel(opId));
    _subscription?.cancel();
    _subscription = null;
  }

  /// Runs the scan, streaming progress to [onProgress].
  ///
  /// [excludedDirNames] should already be lowercased. [allowedExtensions]
  /// (lowercased, incl. leading dot) restricts which files are considered;
  /// null means every file. [skipHidden] skips dot-prefixed files and folders;
  /// [skipBundles] treats macOS packages as opaque.
  Future<List<DuplicateGroup>> scan({
    required List<String> roots,
    int minSize = 1,
    Set<String> excludedDirNames = const {},
    Set<String>? allowedExtensions,
    bool skipHidden = true,
    bool skipBundles = true,
    void Function(ScanProgress)? onProgress,
  }) async {
    if (roots.isEmpty || _cancelled) return const [];

    final core = native.NativeCore.instance;
    final opId = core.newOpId();
    _opId = opId;

    final completer = Completer<List<DuplicateGroup>>();
    final request = rust.ScanRequest(
      roots: roots,
      minSize: BigInt.from(minSize),
      excludedDirNames: excludedDirNames.toList(),
      allowedExtensions: allowedExtensions?.toList(),
      skipHidden: skipHidden,
      skipBundles: skipBundles,
    );

    void finish(List<DuplicateGroup> groups) {
      _opId = null;
      _subscription = null;
      if (!completer.isCompleted) completer.complete(groups);
    }

    try {
      _subscription =
          core.scanDuplicates(request: request, opId: opId).listen(
        (event) {
          switch (event) {
            case native.ScanEvent_Progress(:final field0):
              if (!_cancelled) onProgress?.call(_toProgress(field0));
            case native.ScanEvent_Done(:final field0):
              finish(_cancelled ? const [] : _toGroups(field0));
          }
        },
        // Any failure resolves the future rather than hanging the UI on a
        // spinner that will never stop.
        onError: (_) => finish(const []),
        onDone: () => finish(const []),
        cancelOnError: true,
      );
    } catch (_) {
      finish(const []);
    }
    return completer.future;
  }

  ScanProgress _toProgress(rust.ScanProgress p) => ScanProgress(
        phase: p.phase == rust.ScanPhase.scanning ? 'Scanning' : 'Comparing',
        filesSeen: p.filesSeen.toInt(),
        filesHashed: p.filesHashed.toInt(),
        hashTotal: p.hashTotal.toInt(),
        currentPath: p.currentPath,
      );

  List<DuplicateGroup> _toGroups(List<rust.DuplicateGroup> groups) => [
        for (final g in groups)
          DuplicateGroup(
            hash: g.hash,
            size: g.size.toInt(),
            files: [
              for (final f in g.files)
                FileEntry(
                  path: f.path,
                  name: f.name,
                  isDirectory: f.isDir,
                  size: f.size.toInt(),
                  modified: DateTime.fromMillisecondsSinceEpoch(f.modifiedMs),
                ),
            ],
          ),
      ];
}

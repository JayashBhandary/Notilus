import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';

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
/// Strategy (the standard two-pass approach): first bucket every file by exact
/// byte size — files of different sizes can't be identical — then hash only the
/// buckets that contain more than one file. This avoids hashing the vast
/// majority of files on disk.
///
/// Create a fresh instance per scan; call [cancel] to stop early.
class DuplicateFinderService {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Stops an in-flight scan. Kills the background isolate immediately — the
  /// crawl only reads the filesystem, so there's nothing to unwind — and
  /// resolves the pending future with an empty result.
  void cancel() {
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _finish(const []);
  }

  /// Directories skipped wholesale: pseudo-filesystems, VM/swap, and nested
  /// mount roots that would otherwise cause redundant or runaway crawls.
  static const _skipPrefixes = <String>[
    '/proc', '/sys', '/dev', '/run',
    '/System/Volumes', '/private/var/vm', '/.Spotlight-V100',
    '/.fseventsd', '/.Trashes',
  ];

  /// Trash / Recycle Bin directories, skipped unconditionally (regardless of
  /// the "include hidden" and "skip dev folders" toggles) — deleted files
  /// shouldn't resurface as duplicates. `.trash-<uid>` is matched by prefix.
  /// Windows: `$Recycle.Bin` / `RECYCLER`. macOS: `.Trash` / `.Trashes`.
  /// Linux: `.local/share/Trash`, `.Trash-1000`.
  static const _alwaysSkipDirNames = <String>{
    r'$recycle.bin', 'recycler',
    '.trash', '.trashes', 'trash',
  };

  bool _isTrashDir(String lowerName) =>
      _alwaysSkipDirNames.contains(lowerName) ||
      lowerName.startsWith('.trash-');

  /// macOS "package" directory extensions — these are folders that macOS
  /// presents as a single opaque item. Descending into them surfaces shared
  /// frameworks/resources as "duplicates" the user can't safely delete without
  /// breaking the app or library, so the walk treats them as leaves.
  static const _bundleExts = <String>{
    '.app', '.framework', '.bundle', '.plugin', '.kext', '.xpc', '.appex',
    '.systemextension', '.qlgenerator', '.prefpane', '.component',
    '.mdimporter', '.wdgt', '.rtfd', '.download',
    '.photoslibrary', '.musiclibrary', '.tvlibrary', '.imovielibrary',
    '.fcpbundle', '.aplibrary', '.pkpass',
  };

  bool _isBundleDir(String lowerName) =>
      _bundleExts.contains(p.extension(lowerName));

  /// Curated dependency / build / cache directory names that almost never
  /// contain user files worth de-duplicating, and which balloon scan time.
  /// Matched case-insensitively against directory basenames.
  static const defaultExcludedDirs = <String>{
    'node_modules', '.git', '.svn', '.hg',
    'venv', '.venv', '__pycache__', 'site-packages',
    '.tox', '.mypy_cache', '.pytest_cache',
    'build', 'dist', 'target', '.gradle', '.dart_tool',
    '.next', '.nuxt', '.parcel-cache',
    'pods', 'carthage', 'deriveddata',
    'vendor', 'bower_components', '.cache', '.terraform', '.cargo',
  };

  Isolate? _isolate;
  ReceivePort? _port;
  Completer<List<DuplicateGroup>>? _completer;

  /// Runs the scan on a background isolate so the UI thread never stalls while
  /// crawling and hashing a large drive. Progress arrives on [onProgress];
  /// [cancel] kills the isolate immediately (the work is read-only, so this is
  /// safe) and resolves the returned future with an empty list.
  ///
  /// [excludedDirNames] should already be lowercased.
  /// [allowedExtensions] (lowercased, incl. leading dot) restricts which files
  /// are considered; null means every file. [skipHidden] skips dot-prefixed
  /// files and folders; [skipBundles] treats macOS packages as opaque.
  Future<List<DuplicateGroup>> scan({
    required List<String> roots,
    int minSize = 1,
    Set<String> excludedDirNames = const {},
    Set<String>? allowedExtensions,
    bool skipHidden = true,
    bool skipBundles = true,
    void Function(ScanProgress)? onProgress,
  }) async {
    final port = ReceivePort();
    final completer = Completer<List<DuplicateGroup>>();
    _port = port;
    _completer = completer;

    port.listen((msg) {
      if (msg is ScanProgress) {
        if (!_cancelled) onProgress?.call(msg);
      } else if (msg is _ScanDone) {
        _finish(msg.groups);
      } else {
        // An uncaught isolate error arrives as a [error, stack] list; treat
        // any other message as a failure so the future can't hang.
        _finish(const []);
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _isolateEntry,
        _ScanRequest(
          sendPort: port.sendPort,
          roots: roots,
          minSize: minSize,
          excludedDirNames: excludedDirNames,
          allowedExtensions: allowedExtensions,
          skipHidden: skipHidden,
          skipBundles: skipBundles,
        ),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
    } catch (_) {
      _finish(const []);
    }
    return completer.future;
  }

  void _finish(List<DuplicateGroup> groups) {
    _port?.close();
    _port = null;
    _isolate = null;
    final c = _completer;
    _completer = null;
    if (c != null && !c.isCompleted) c.complete(groups);
  }

  /// Isolate entrypoint: runs the crawl and streams progress back.
  static Future<void> _isolateEntry(_ScanRequest req) async {
    final svc = DuplicateFinderService();
    final groups = await svc._scanCore(
      roots: req.roots,
      minSize: req.minSize,
      excludedDirNames: req.excludedDirNames,
      allowedExtensions: req.allowedExtensions,
      skipHidden: req.skipHidden,
      skipBundles: req.skipBundles,
      onProgress: req.sendPort.send,
    );
    req.sendPort.send(_ScanDone(groups));
  }

  Future<List<DuplicateGroup>> _scanCore({
    required List<String> roots,
    int minSize = 1,
    Set<String> excludedDirNames = const {},
    Set<String>? allowedExtensions,
    bool skipHidden = true,
    bool skipBundles = true,
    void Function(ScanProgress)? onProgress,
  }) async {
    // Bucket files by size. Track visited paths so a file reachable from two
    // overlapping roots (e.g. "/" and "/Users/me") isn't counted against itself.
    final bySize = <int, List<FileEntry>>{};
    final visited = <String>{};
    var seen = 0;

    void report(String phase, {String path = '', int hashed = 0, int total = 0}) {
      onProgress?.call(ScanProgress(
        phase: phase,
        filesSeen: seen,
        filesHashed: hashed,
        hashTotal: total,
        currentPath: path,
      ));
    }

    for (final root in roots) {
      if (_cancelled) break;
      await _walk(
        Directory(root),
        minSize: minSize,
        excludedDirNames: excludedDirNames,
        allowedExtensions: allowedExtensions,
        skipHidden: skipHidden,
        skipBundles: skipBundles,
        visited: visited,
        onFile: (entry) {
          bySize.putIfAbsent(entry.size, () => []).add(entry);
          seen++;
          if (seen % 200 == 0) report('Scanning', path: entry.path);
        },
        onDir: (path) {
          if (seen % 50 == 0) report('Scanning', path: path);
        },
      );
    }
    if (_cancelled) return const [];

    // Only size-collision buckets are worth hashing.
    final candidates = <FileEntry>[];
    for (final list in bySize.values) {
      if (list.length > 1) candidates.addAll(list);
    }
    final hashTotal = candidates.length;

    final byHash = <String, List<FileEntry>>{};
    var hashed = 0;
    for (final entry in candidates) {
      if (_cancelled) return const [];
      final hash = await _hashFile(entry.path);
      hashed++;
      if (hashed % 20 == 0 || hashed == hashTotal) {
        report('Comparing',
            path: entry.path, hashed: hashed, total: hashTotal);
      }
      if (hash == null) continue; // unreadable — skip
      // Bucket by hash *and* size to be safe against theoretical collisions.
      byHash.putIfAbsent('${entry.size}:$hash', () => []).add(entry);
    }

    final groups = <DuplicateGroup>[];
    byHash.forEach((key, files) {
      if (files.length < 2) return;
      final hash = key.substring(key.indexOf(':') + 1);
      files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      groups.add(DuplicateGroup(
        hash: hash,
        size: files.first.size,
        files: files,
      ));
    });
    // Biggest reclaimable savings first.
    groups.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));
    return groups;
  }

  /// Manual recursion so a single permission-denied directory doesn't abort
  /// the whole crawl (a recursive [Directory.list] would surface the error and
  /// stop). Hidden dirs, symlinks and pseudo-filesystems are skipped.
  Future<void> _walk(
    Directory dir, {
    required int minSize,
    required Set<String> excludedDirNames,
    required Set<String>? allowedExtensions,
    required bool skipHidden,
    required bool skipBundles,
    required Set<String> visited,
    required void Function(FileEntry) onFile,
    required void Function(String) onDir,
  }) async {
    if (_cancelled) return;
    if (_shouldSkipDir(dir.path)) return;
    onDir(dir.path);

    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      return; // permission denied / vanished — skip quietly
    }

    for (final entity in children) {
      if (_cancelled) return;
      final name = p.basename(entity.path);
      final lower = name.toLowerCase();
      if (entity is Directory) {
        if (_isTrashDir(lower)) continue; // always skip Trash / Recycle Bin
        if (skipBundles && _isBundleDir(lower)) continue; // opaque .app/etc.
        if (skipHidden && name.startsWith('.')) continue;
        if (excludedDirNames.contains(lower)) continue;
        await _walk(
          entity,
          minSize: minSize,
          excludedDirNames: excludedDirNames,
          allowedExtensions: allowedExtensions,
          skipHidden: skipHidden,
          skipBundles: skipBundles,
          visited: visited,
          onFile: onFile,
          onDir: onDir,
        );
      } else if (entity is File) {
        if (skipHidden && name.startsWith('.')) continue;
        if (allowedExtensions != null &&
            !allowedExtensions.contains(p.extension(name).toLowerCase())) {
          continue;
        }
        if (!visited.add(entity.path)) continue; // reached via another root
        final entry = await FileEntry.from(entity);
        if (entry == null || entry.isDirectory) continue;
        if (entry.size < minSize) continue;
        onFile(entry);
      }
    }
  }

  bool _shouldSkipDir(String path) {
    for (final prefix in _skipPrefixes) {
      if (path == prefix || path.startsWith('$prefix/')) return true;
    }
    return false;
  }

  /// Streams the file through SHA-256 so large files don't load fully into
  /// memory. Returns null if the file can't be read.
  Future<String?> _hashFile(String path) async {
    try {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    } catch (_) {
      return null;
    }
  }
}

/// Parameters shipped to the scan isolate. All fields are sendable.
class _ScanRequest {
  _ScanRequest({
    required this.sendPort,
    required this.roots,
    required this.minSize,
    required this.excludedDirNames,
    required this.allowedExtensions,
    required this.skipHidden,
    required this.skipBundles,
  });

  final SendPort sendPort;
  final List<String> roots;
  final int minSize;
  final Set<String> excludedDirNames;
  final Set<String>? allowedExtensions;
  final bool skipHidden;
  final bool skipBundles;
}

/// Terminal message sent from the isolate carrying the finished result.
/// Wrapping it in a dedicated class keeps the port listener's type check
/// reliable (a bare `List` can arrive as `List<dynamic>` across isolates).
class _ScanDone {
  _ScanDone(this.groups);
  final List<DuplicateGroup> groups;
}

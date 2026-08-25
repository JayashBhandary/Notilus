import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/file_entry.dart';
import '../../models/media_kind.dart';
import '../remote/remote_path.dart';
import '../thumbnail_service.dart';
import 'leave_behind.dart';
import 'sidecar_thumbnails.dart';

/// Fills `.thumbs` folders without waiting for anyone to look at the files.
///
/// # Why this exists
///
/// Everything else in this directory is demand-driven: a tile scrolls into
/// view, and the thumbnail behind it gets made and left beside the data. That
/// is right for the machine doing the scrolling and useless for every other
/// one. A phone opening the same folder over SMB has no way to *make* a
/// thumbnail — it would have to pull every full-size photo to do it — so it
/// finds only what this machine happened to scroll past. A folder nobody
/// opened on the desktop has no `.thumbs` at all, and a folder that was opened
/// has thumbnails for the two screenfuls that were on display.
///
/// So the folders a share publishes are walked and filled ahead of time. The
/// machine holding the data is the only one that can do this work, and it is
/// the one place doing it once is enough.
///
/// # What it costs
///
/// One decode per file, once, and roughly 30 KB per thumbnail on the drive the
/// photos are already on. It runs behind the interactive path — a folder the
/// user is looking at now is always served first — and one file at a time on
/// the share lane, so a tree of 40,000 photos fills up over an evening instead
/// of taking the machine away for ten minutes.
class SidecarWarmer {
  SidecarWarmer._();

  static final SidecarWarmer instance = SidecarWarmer._();

  /// Files warmed at once for the folder the user is actually looking at.
  /// Matches the render gate's own appetite without monopolising it.
  static const int _browseConcurrency = 3;

  /// How long a share walk waits while the browse lane is busy. Long enough to
  /// stay out of the way of a scroll, short enough not to stall a whole tree
  /// behind one navigation.
  static const Duration _yield = Duration(milliseconds: 250);

  /// Folders filled this session, so re-navigating one doesn't walk it again.
  /// Bounded: a deep tree would otherwise remember every folder it passed.
  static const int _maxRemembered = 2048;

  /// Folder to how many thumbnailable files it held when it was filled.
  ///
  /// Not a plain set, because a folder is watched while it is open and every
  /// thumbnail written into its `.thumbs` can come back as a change event. A
  /// remembered count means the reload that follows costs nothing, while a
  /// photo genuinely added to the folder still gets one.
  final LinkedHashMap<String, int> _done = LinkedHashMap();

  /// Folder walks in flight, keyed by the folder, so two navigations to the
  /// same place — or a share walk arriving on top of a browse — do the work
  /// once.
  final Map<String, Future<void>> _inFlight = {};

  /// Share roots being walked, so stopping the server stops the walk.
  final Map<String, _Walk> _walks = {};

  int _browsing = 0;

  /// What the warmer is doing, for the sharing screen to show. Null when it is
  /// idle.
  final ValueNotifier<String?> status = ValueNotifier<String?>(null);

  /// Thumbnails written since the app started. Only ever read for display.
  int get written => _written;
  int _written = 0;

  /// Fills [folder]'s `.thumbs` for everything in it, not only what is on
  /// screen.
  ///
  /// The returned future is there for tests and for anything that wants to
  /// know when the folder is complete; nothing needs to await it. The grid is
  /// already drawing from the same `.thumbs` and picks each thumbnail up as it
  /// lands.
  Future<void> warmFolder(String folder, List<FileEntry> entries) {
    if (!_isLocal(folder)) return Future.value();
    final wanted = [
      for (final entry in entries)
        if (_worthThumbnailing(entry)) entry,
    ];
    if (_done[folder] == wanted.length) return Future.value();
    if (wanted.isEmpty) {
      _remember(folder, 0);
      return Future.value();
    }
    return _warmFolder(folder, wanted, interactive: true);
  }

  /// Walks [root] and fills every folder under it.
  ///
  /// For the folders a share publishes: the clients reading them cannot make a
  /// thumbnail themselves, so this machine makes all of them.
  /// As with [warmFolder], the future is informational — a share fills itself
  /// while the app gets on with whatever else it was doing.
  Future<void> warmShare(String root) {
    if (!_isLocal(root) || _walks.containsKey(root)) return Future.value();
    final walk = _Walk();
    _walks[root] = walk;
    return _walkTree(root, walk).whenComplete(() {
      _walks.remove(root);
      if (_walks.isEmpty) status.value = null;
    });
  }

  /// Stops every share walk. Browsing is unaffected — it follows the user.
  void stopShares() {
    for (final walk in _walks.values) {
      walk.cancelled = true;
    }
    _walks.clear();
    status.value = null;
  }

  @visibleForTesting
  void debugReset() {
    stopShares();
    _done.clear();
    _inFlight.clear();
    _written = 0;
    _browsing = 0;
    status.value = null;
  }

  // ── internals ────────────────────────────────────────────────────────────

  bool _isLocal(String path) => path.isNotEmpty && !VPath.isRemote(path);

  /// Whether a thumbnail of this entry is something any machine could use.
  ///
  /// Text snippets are drawn from the file at display time and never stored,
  /// so a `.thumbs` entry for one would be a picture nobody reads.
  bool _worthThumbnailing(FileEntry entry) {
    if (entry.isDirectory) return false;
    // Hidden files, and the AppleDouble `._name` companions a Mac leaves on
    // every non-HFS volume — same extension as the file they shadow, four
    // kilobytes of metadata inside, and a decoder spawn wasted on each one.
    if (entry.name.startsWith('.')) return false;
    final ext = entry.extension;
    // SVG is drawn by a vector renderer at display time, never stored.
    if (ext == '.svg' || ext == '.svgz') return false;
    final service = ThumbnailService.instance;
    return kImageExtensions.contains(ext) ||
        ext == '.pdf' ||
        service.isVideo(entry) ||
        service.hasEmbeddedPreview(entry);
  }

  Future<void> _warmFolder(
    String folder,
    List<FileEntry> entries, {
    required bool interactive,
  }) {
    final existing = _inFlight[folder];
    if (existing != null) return existing;
    final future = _fill(folder, entries, interactive: interactive);
    _inFlight[folder] = future;
    return future.whenComplete(() => _inFlight.remove(folder));
  }

  Future<void> _fill(
    String folder,
    List<FileEntry> entries, {
    required bool interactive,
  }) async {
    if (interactive) _browsing++;
    try {
      final queue = Queue<FileEntry>.of(entries);
      final workers = interactive ? _browseConcurrency : 1;
      final total = entries.length;
      await Future.wait([
        for (var i = 0; i < workers; i++)
          _drain(queue, interactive: interactive),
      ]);
      _remember(folder, total);
    } finally {
      if (interactive) _browsing--;
    }
  }

  Future<void> _drain(
    Queue<FileEntry> queue, {
    required bool interactive,
  }) async {
    while (queue.isNotEmpty) {
      // A share walk gives way to the folder someone is looking at: the same
      // render gate serves both, and a tile the user is waiting on should not
      // be queued behind a thousand files nobody has asked for.
      while (!interactive && _browsing > 0) {
        await Future<void>.delayed(_yield);
      }
      final entry = queue.removeFirst();
      final sidecars = SidecarThumbnails.instance;
      // The drive turned out to be read-only, or the folder is a `.thumbs`
      // itself. Nothing in this folder will take a write, so stop.
      if (!sidecars.writesBesideData(entry)) return;
      try {
        if (await sidecars.lookup(entry) != null) continue;
        await leaveThumbnailBeside(entry, entry.path);
        _written++;
      } catch (_) {
        // A file that vanished mid-walk, a decoder that gave up, a drive
        // unplugged. None of it is worth stopping the rest of the folder for.
      }
    }
  }

  void _remember(String folder, int files) {
    _done.remove(folder);
    _done[folder] = files;
    while (_done.length > _maxRemembered) {
      _done.remove(_done.keys.first);
    }
  }

  /// Breadth-first, so the folders nearest the top of a share — the ones a
  /// client opens first — are filled first.
  Future<void> _walkTree(String root, _Walk walk) async {
    final pending = Queue<String>()..add(root);
    var folders = 0;
    while (pending.isNotEmpty && !walk.cancelled) {
      final folder = pending.removeFirst();
      final listing = await _read(folder);
      if (listing == null) continue;
      pending.addAll(listing.folders);
      if (listing.files.isEmpty ||
          _done[folder] == listing.files.length) {
        continue;
      }
      folders++;
      status.value = 'Preparing thumbnails · ${p.basename(folder)}';
      await _warmFolder(folder, listing.files, interactive: false);
      if (walk.cancelled) return;
    }
    if (!walk.cancelled && folders > 0) {
      status.value = null;
    }
  }

  Future<_Listing?> _read(String folder) async {
    try {
      final dir = Directory(folder);
      final folders = <String>[];
      final files = <FileEntry>[];
      await for (final item in dir.list(followLinks: false)) {
        final name = p.basename(item.path);
        // `.thumbs` is ours and holds no data; the rest of the dot-folders on a
        // volume are caches, trash and Spotlight indexes, and thumbnailing
        // those would fill a share with pictures of nothing.
        if (name.startsWith('.')) continue;
        if (item is Directory) {
          folders.add(item.path);
          continue;
        }
        if (item is! File) continue;
        final entry = await FileEntry.from(item);
        if (entry != null && _worthThumbnailing(entry)) files.add(entry);
      }
      return _Listing(folders, files);
    } catch (_) {
      // Permission denied, or a folder that went away between listings.
      return null;
    }
  }
}

class _Listing {
  const _Listing(this.folders, this.files);

  final List<String> folders;
  final List<FileEntry> files;
}

class _Walk {
  bool cancelled = false;
}

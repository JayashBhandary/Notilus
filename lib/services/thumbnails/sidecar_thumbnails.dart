import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/file_entry.dart';
import '../native_core.dart';
import '../remote/remote_hub.dart';
import '../remote/remote_path.dart';
import '../thumbnail_service.dart';
import 'sidecar_naming.dart';
import 'sidecar_policy.dart';
import 'sidecar_store.dart';

/// A thumbnail that was found or written beside its file.
///
/// Local sidecars come back as a path so the image widget can stream the file
/// itself; remote ones come back as bytes, because there is no local file and
/// downloading a 30 KB WebP is the cheap part of the operation.
class SidecarHit {
  const SidecarHit.file(File this.file) : bytes = null;
  const SidecarHit.bytes(Uint8List this.bytes) : file = null;

  final File? file;
  final Uint8List? bytes;
}

/// Thumbnails stored beside the data, so they are found rather than remade.
///
/// # What this fixes
///
/// The machine-local cache this sits in front of is keyed on absolute paths, so
/// nothing was ever shared. An external SSD full of photos re-rendered on every
/// laptop it was plugged into. A MinIO bucket browsed from three machines had
/// three sets of thumbnails, and none of them existed until somebody opened
/// every file one at a time to find out what was in it.
///
/// # How a folder is checked
///
/// One listing of `.thumbs` per folder answers the question for every file in
/// it at once — a `readdir` locally, a single prefixed `LIST` on S3. Names are
/// self-describing (see [sidecarName]), so nothing is opened to find out
/// whether it is current. Folders are remembered briefly, because a grid asks
/// about forty files in the time it takes to scroll once.
///
/// # What is never done
///
/// Nothing is downloaded to make a thumbnail. On a cloud source a thumbnail
/// appears when the bytes were already being fetched for some other reason —
/// the user previewed or opened the file — and is left behind for next time.
/// Scrolling past a folder of 4 GB videos on S3 costs nothing.
class SidecarThumbnails {
  SidecarThumbnails._();

  static final SidecarThumbnails instance = SidecarThumbnails._();

  /// How long a folder's `.thumbs` listing is trusted.
  ///
  /// Long enough to cover a scroll through one folder, short enough that a
  /// thumbnail another machine wrote turns up without a restart.
  static const Duration _listingTtl = Duration(seconds: 30);

  /// Folders whose listings are remembered. Bounded because a deep tree walk
  /// would otherwise hold every folder it passed through.
  static const int _maxFolders = 64;

  /// Remote thumbnails held in memory after being downloaded, so scrolling back
  /// up a grid doesn't re-fetch them. Each is tens of kilobytes.
  static const int _maxRemoteBytesCached = 200;

  final LinkedHashMap<String, _FolderListing> _listings = LinkedHashMap();

  /// Folders that refused a write: a read-only drive, a share without write
  /// access, a bucket without `PutObject`. Remembered so a scrolling grid
  /// doesn't retry a doomed upload once per tile.
  final Set<String> _unwritable = {};

  final LinkedHashMap<String, Uint8List> _remoteBytes = LinkedHashMap();

  /// Generation already under way, keyed by folder and name, so two tiles for
  /// the same file don't both encode it.
  final Map<String, Future<SidecarHit?>> _inFlight = {};

  /// Whether [entry] would have its thumbnail written beside it.
  bool writesBesideData(FileEntry entry) {
    final folder = _folderOf(entry);
    return SidecarPolicy.homeFor(folder) == ThumbnailHome.sidecar &&
        !_unwritable.contains(folder);
  }

  /// Looks for an existing thumbnail. Never generates and never downloads the
  /// source file.
  ///
  /// Reads from `.thumbs` wherever one is found — including on the internal
  /// disk, which never gets written to. A folder copied off a shared drive
  /// arrives with its thumbnails, and this is what makes them count.
  Future<SidecarHit?> lookup(FileEntry entry) async {
    final folder = _folderOf(entry);
    final wanted = _nameFor(entry);

    final listing = await _listingFor(folder);
    if (listing == null || !listing.names.contains(wanted)) return null;

    final store = await _storeFor(folder);
    if (store == null) return null;

    final local = await store.localPathFor(wanted);
    if (local != null) return SidecarHit.file(File(local));

    final cacheKey = _cacheKey(folder, wanted);
    final cached = _remoteBytes.remove(cacheKey);
    if (cached != null) {
      _remoteBytes[cacheKey] = cached; // Most recently used.
      return SidecarHit.bytes(cached);
    }
    final bytes = await store.read(wanted);
    if (bytes == null) {
      // Listed but unreadable, or larger than a thumbnail has any business
      // being. Forget the listing so the next look re-checks rather than
      // reporting a hit that never resolves.
      _listings.remove(folder);
      return null;
    }
    _rememberRemote(cacheKey, bytes);
    return SidecarHit.bytes(bytes);
  }

  /// Makes a thumbnail for [entry] from a local copy of it and stores it.
  ///
  /// [sourcePath] is the file itself for a local source, or the downloaded
  /// temporary copy for a remote one.
  Future<SidecarHit?> generateFromFile(FileEntry entry, String sourcePath) =>
      _generate(entry, () async {
        try {
          final out = await NativeCore.instance.thumbnailBytes(
            src: sourcePath,
            maxDim: kSidecarMasterDim,
          );
          return out.bytes;
        } catch (_) {
          // HEIC, raw, and the rest of what the in-process decoder can't open.
          // Left to fail, a folder of iPhone photos produced no `.thumbs` at
          // all — the one case where the OS knows the format and this process
          // doesn't. See [ThumbnailService.imageThumbnail].
          final bytes = await _viaSystemDecoder(entry, sourcePath);
          if (bytes == null) rethrow;
          return bytes;
        }
      });

  /// Re-encodes what the operating system's own decoder makes of [sourcePath],
  /// or null when this machine has no renderer for the format.
  Future<Uint8List?> _viaSystemDecoder(
    FileEntry entry,
    String sourcePath,
  ) async {
    final local = FileEntry(
      path: sourcePath,
      name: entry.name,
      isDirectory: false,
      size: entry.size,
      modified: entry.modified,
    );
    final service = ThumbnailService.instance;
    if (!service.needsExternalDecoder(local)) return null;
    final rendered =
        await service.imageThumbnail(local, dim: kSidecarMasterDim);
    if (rendered == null) return null;
    final out = await NativeCore.instance.thumbnailFromBytes(
      source: await rendered.readAsBytes(),
      maxDim: kSidecarMasterDim,
    );
    return out.bytes;
  }

  /// Makes a thumbnail from bytes already in hand and stores it.
  ///
  /// Two callers: a rendered PDF page or extracted video frame, which arrive as
  /// PNG from an external tool, and a cloud file whose bytes were downloaded to
  /// be previewed anyway.
  Future<SidecarHit?> generateFromBytes(FileEntry entry, Uint8List source) =>
      _generate(entry, () async {
        final out = await NativeCore.instance.thumbnailFromBytes(
          source: source,
          maxDim: kSidecarMasterDim,
        );
        return out.bytes;
      });

  /// Deletes thumbnails in [folder]'s `.thumbs` that describe a version of a
  /// file that no longer exists.
  ///
  /// Nothing is removed on the strength of a file being *absent*. A listing can
  /// be partial for reasons that have nothing to do with the files — hidden
  /// entries filtered out, a page of a paginated bucket, a permission denied
  /// halfway down — and reading that as "these files are gone" would throw away
  /// work every other machine on the source is relying on. So an entry is only
  /// swept when [contents] contains a file of that name whose size or time has
  /// since changed: the file is demonstrably still there, and demonstrably not
  /// the one this thumbnail shows.
  ///
  /// The cost of that caution is thumbnails of genuinely deleted files, which
  /// stay. They are tens of kilobytes each, and the alternative is deleting
  /// somebody else's.
  ///
  /// Returns how many were removed.
  Future<int> sweep(String folder, List<FileEntry> contents) async {
    // Reuses the listing a scrolling grid needs anyway rather than asking the
    // source again — on a bucket that is the difference between one LIST per
    // folder visited and two.
    final listing = await _listingFor(folder);
    if (listing == null || listing.names.isEmpty) return 0;

    final current = <String>{};
    final known = <String>{};
    for (final entry in contents) {
      if (entry.isDirectory) continue;
      known.add(sidecarPrefix(entry.name));
      current.add(_nameFor(entry));
    }
    if (known.isEmpty) return 0;

    final store = await _storeFor(folder);
    if (store == null) return 0;

    final stale = <String>[];
    for (final name in listing.names) {
      if (current.contains(name)) continue;
      // Only entries that look like ours *and* name a file just seen. Anything
      // else in `.thumbs` was put there by something else and is not this
      // code's to delete.
      final prefix = name.contains('_')
          ? '${name.substring(0, name.indexOf('_'))}_'
          : null;
      if (prefix == null || !known.contains(prefix)) continue;
      stale.add(name);
    }

    for (final name in stale) {
      await store.remove(name);
      listing.names.remove(name);
    }
    return stale.length;
  }

  /// Deletes the thumbnails of files that have just been deleted or renamed.
  ///
  /// Unlike [sweep], this is not inference: the caller has just removed these
  /// exact files and says so, and every thumbnail whose name describes one of
  /// them goes — the current one and any older version still sitting there.
  ///
  /// Not an optimisation. A thumbnail is a readable picture of the file, so one
  /// left in a folder after its photo is deleted is a copy of that photo the
  /// user believes they got rid of — on a share, a copy everyone else can still
  /// see. Deleting a file has to delete what it looks like too.
  ///
  /// Directories need no special handling: they never have thumbnails of their
  /// own, and a folder's `.thumbs` lives inside it and goes with it.
  Future<void> forget(Iterable<String> paths) async {
    final byFolder = <String, Set<String>>{};
    for (final path in paths) {
      final remote = VPath.isRemote(path);
      final folder = remote ? VPath.dirname(path) : p.dirname(path);
      final name = remote ? VPath.basename(path) : p.basename(path);
      if (name.isEmpty) continue;
      (byFolder[folder] ??= <String>{}).add(sidecarPrefix(name));
    }

    for (final entry in byFolder.entries) {
      final folder = entry.key;
      final listing = await _listingFor(folder);
      if (listing == null || listing.names.isEmpty) continue;
      final doomed = [
        for (final name in listing.names)
          if (entry.value.any(name.startsWith)) name,
      ];
      if (doomed.isEmpty) continue;
      final store = await _storeFor(folder);
      if (store == null) continue;
      for (final name in doomed) {
        await store.remove(name);
        listing.names.remove(name);
        _remoteBytes.remove(_cacheKey(folder, name));
      }
    }
  }

  /// Forgets every cached listing and every downloaded thumbnail.
  ///
  /// The blunt instrument, for when something outside this class changed a
  /// source wholesale — a share reconnected, a drive remounted. Ordinary file
  /// operations do not need it: a delete, a rename and a move all name the
  /// files they touched, and [forget] uses that to remove exactly the right
  /// thumbnails instead of throwing away work for a whole tree.
  void invalidate() {
    _listings.clear();
    _remoteBytes.clear();
  }

  /// Also forgets which folders refused a write, which [invalidate] keeps: a
  /// drive that was read-only a minute ago still is, and re-probing it once per
  /// tile is the thing that memory exists to prevent. Reconnecting a source, or
  /// a test, is when it should go.
  @visibleForTesting
  void debugReset() {
    invalidate();
    _unwritable.clear();
    _inFlight.clear();
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<SidecarHit?> _generate(
    FileEntry entry,
    Future<Uint8List> Function() encode,
  ) {
    final folder = _folderOf(entry);
    if (SidecarPolicy.homeFor(folder) != ThumbnailHome.sidecar) {
      return Future.value(null);
    }
    if (_unwritable.contains(folder)) return Future.value(null);

    final wanted = _nameFor(entry);
    final key = '$folder $wanted';
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _generateOnce(folder, wanted, encode);
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<SidecarHit?> _generateOnce(
    String folder,
    String wanted,
    Future<Uint8List> Function() encode,
  ) async {
    final store = await _storeFor(folder);
    if (store == null) return null;

    final Uint8List bytes;
    try {
      bytes = await encode();
    } catch (_) {
      // Not an image, a decoder that gave up, a source too large to decode.
      // The caller falls back to a glyph; nothing is written.
      return null;
    }

    if (!await store.write(wanted, bytes)) {
      // The source won't take writes. Remember that, so the rest of this
      // folder doesn't attempt the same upload forty more times.
      _unwritable.add(folder);
      return null;
    }
    _listings[folder]?.names.add(wanted);

    final local = await store.localPathFor(wanted);
    if (local != null) return SidecarHit.file(File(local));
    _rememberRemote(_cacheKey(folder, wanted), bytes);
    return SidecarHit.bytes(bytes);
  }

  String _folderOf(FileEntry entry) => VPath.isRemote(entry.path)
      ? VPath.dirname(entry.path)
      : p.dirname(entry.path);

  String _nameFor(FileEntry entry) => sidecarName(
        name: entry.name,
        size: entry.size,
        modifiedMs: entry.modified.millisecondsSinceEpoch,
      );

  Future<_FolderListing?> _listingFor(String folder) async {
    final held = _listings[folder];
    if (held != null && !held.isStale) {
      _listings.remove(folder);
      _listings[folder] = held; // Most recently used.
      return held;
    }

    final store = await _storeFor(folder);
    if (store == null) return null;
    final names = await store.listNames();
    if (names == null) {
      // No `.thumbs` here. Remembered as empty rather than as nothing, so a
      // folder of a thousand files doesn't ask a thousand times.
      final empty = _FolderListing(<String>{});
      _remember(folder, empty);
      return empty;
    }
    final listing = _FolderListing(names);
    _remember(folder, listing);
    return listing;
  }

  void _remember(String folder, _FolderListing listing) {
    _listings.remove(folder);
    _listings[folder] = listing;
    while (_listings.length > _maxFolders) {
      _listings.remove(_listings.keys.first);
    }
  }

  /// Sidecar names hold no path, deliberately — that is what lets a folder
  /// carry its thumbnails to another machine. In memory the folder has to go
  /// back on, or two folders each holding a `DSC_0001.jpg` of the same size and
  /// time would share one entry and show each other's photo.
  String _cacheKey(String folder, String name) => '$folder $name';

  void _rememberRemote(String key, Uint8List bytes) {
    _remoteBytes.remove(key);
    _remoteBytes[key] = bytes;
    while (_remoteBytes.length > _maxRemoteBytesCached) {
      _remoteBytes.remove(_remoteBytes.keys.first);
    }
  }

  Future<SidecarStore?> _storeFor(String folder) async {
    if (!VPath.isRemote(folder)) return LocalSidecarStore(folder);
    final ref = VPath.parse(folder);
    if (ref == null) return null;
    try {
      final fs = await RemoteHub.instance.fsFor(ref.connectionId);
      return RemoteSidecarStore(fs, folder);
    } catch (_) {
      // Not connected, or credentials gone. Nothing to read and nowhere to
      // write; the caller falls back.
      return null;
    }
  }
}

class _FolderListing {
  _FolderListing(this.names) : _at = DateTime.now();

  final Set<String> names;
  final DateTime _at;

  bool get isStale =>
      DateTime.now().difference(_at) > SidecarThumbnails._listingTtl;
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../remote/remote_file_system.dart';
import '../remote/remote_path.dart';
import 'sidecar_naming.dart';

/// One folder's `.thumbs`, wherever that folder actually lives.
///
/// The two implementations differ only in how they reach the bytes — a local
/// path or a provider call — so everything above this point is written once and
/// works the same on an external SSD, an SMB share and an S3 bucket.
///
/// Nothing here creates `.thumbs` speculatively. The folder appears the first
/// time something is written into it, so browsing a read-only source leaves no
/// trace at all.
abstract class SidecarStore {
  /// The names currently in `.thumbs`, or null when it can't be read.
  ///
  /// One call answers "which of this folder's files already have a thumbnail"
  /// for every file at once. Null means the folder has no `.thumbs` yet, or
  /// isn't reachable — both cases mean "no hits", and neither is an error.
  Future<Set<String>?> listNames();

  /// Reads one thumbnail. Null when it's missing, unreadable, or bigger than
  /// [kMaxSidecarBytes] — a `.thumbs` on a shared source is writable by other
  /// people, and nothing here trusts its contents on faith.
  Future<Uint8List?> read(String name);

  /// Writes one thumbnail, returning false when the source won't take it.
  ///
  /// A read-only drive, a share mounted without write access, a bucket without
  /// `PutObject`: all expected, none an error worth showing. The caller falls
  /// back to the machine-local cache.
  Future<bool> write(String name, Uint8List bytes);

  /// Deletes one thumbnail. Used only to sweep entries whose file is gone or
  /// has changed — never called on anything outside `.thumbs`.
  Future<void> remove(String name);

  /// A local path for [name], when there is one and it is a plausible size.
  ///
  /// Lets the local case hand a `File` straight to the image widget instead of
  /// reading it into the Dart heap first. Null for anything remote, and null
  /// for an entry past [kMaxSidecarBytes].
  Future<String?> localPathFor(String name) async => null;
}

/// `.thumbs` inside a folder on a mounted filesystem — an external drive, a
/// mounted share, anything `dart:io` can reach by path.
class LocalSidecarStore implements SidecarStore {
  LocalSidecarStore(this.folder);

  /// The folder being described, not the `.thumbs` inside it.
  final String folder;

  Directory get _dir => Directory(p.join(folder, kSidecarDir));

  @override
  Future<String?> localPathFor(String name) async {
    // Size-checked even though nothing is read here: the path is handed
    // straight to an image widget, so this is the only place the cap can be
    // applied. A `.thumbs` on a mounted share is writable by other people, and
    // a gigabyte-long "thumbnail" is not decoded on their word.
    try {
      final file = File(p.join(folder, kSidecarDir, name));
      final length = await file.length();
      if (length <= 0 || length > kMaxSidecarBytes) return null;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Set<String>?> listNames() async {
    try {
      final dir = _dir;
      if (!await dir.exists()) return null;
      final names = <String>{};
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File) names.add(p.basename(entry.path));
      }
      return names;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    try {
      final file = File(p.join(folder, kSidecarDir, name));
      final length = await file.length();
      if (length <= 0 || length > kMaxSidecarBytes) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> write(String name, Uint8List bytes) async {
    try {
      final dir = _dir;
      if (!await dir.exists()) await dir.create(recursive: true);
      // Written beside the target and renamed, so another Notilus reading the
      // same share never sees a half-written file and cache it as real.
      final staging = File(p.join(dir.path, '$name.part'));
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(p.join(dir.path, name));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> remove(String name) async {
    try {
      await File(p.join(folder, kSidecarDir, name)).delete();
    } catch (_) {
      // Already gone, or not ours to delete. Either way there is nothing to do.
    }
  }
}

/// `.thumbs` inside a folder on a remote source — SMB, SFTP, WebDAV, S3/MinIO,
/// Drive.
///
/// This is the case the whole design is for. A bucket browsed from three
/// machines used to mean three sets of thumbnails, none of which existed until
/// somebody opened every file; now the first machine to look at a file leaves
/// the thumbnail where the other two will find it.
class RemoteSidecarStore implements SidecarStore {
  RemoteSidecarStore(this.fs, this.folderVPath);

  final RemoteFileSystem fs;
  final String folderVPath;

  String _vpath(String name) =>
      VPath.join(VPath.join(folderVPath, kSidecarDir), name);

  @override
  Future<String?> localPathFor(String name) async => null;

  @override
  Future<Set<String>?> listNames() async {
    try {
      final entries = await fs.list(VPath.join(folderVPath, kSidecarDir));
      return {
        for (final entry in entries)
          if (!entry.isDirectory) entry.name,
      };
    } catch (_) {
      // No `.thumbs` on this folder yet, or no permission to look. Both mean
      // "nothing cached", and neither is worth reporting to the user.
      return null;
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    try {
      final download = await fs.download(_vpath(name));
      // The length is -1 on providers that won't say, so the guard is applied
      // to what actually arrives as well as to what was promised.
      if (download.length > kMaxSidecarBytes) return null;
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in download.stream) {
        buffer.add(chunk);
        if (buffer.length > kMaxSidecarBytes) return null;
      }
      final bytes = buffer.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> write(String name, Uint8List bytes) async {
    try {
      // Providers that need the folder to exist get it made; the ones that
      // treat a path as a key (S3, and anything else prefix-based) no-op here.
      try {
        await fs.createDirectory(VPath.join(folderVPath, kSidecarDir));
      } catch (_) {
        // Already there, or not a concept this provider has.
      }
      await fs.upload(
        vpath: _vpath(name),
        data: Stream.value(bytes),
        length: bytes.length,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> remove(String name) async {
    try {
      await fs.delete(_vpath(name), isDirectory: false);
    } catch (_) {
      // Nothing to do — see LocalSidecarStore.remove.
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../providers/copy_jobs_provider.dart';
import 'remote_file_system.dart';
import 'remote_hub.dart';
import 'remote_path.dart';

/// One item that couldn't be transferred, with the reason to show for it.
class TransferFailure {
  const TransferFailure({required this.path, required this.error});

  final String path;
  final String error;
}

/// How a transfer ended. Shaped like the Rust core's `OpResult` so callers can
/// report a local copy and a cloud copy through the same code.
class TransferReport {
  const TransferReport({
    required this.completed,
    required this.failed,
    required this.cancelled,
  });

  const TransferReport.empty()
      : completed = const [],
        failed = const [],
        cancelled = false;

  final List<String> completed;
  final List<TransferFailure> failed;
  final bool cancelled;

  bool get isSuccess => failed.isEmpty && !cancelled;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// One file or folder to create at the destination.
class _PlanItem {
  const _PlanItem({
    required this.source,
    required this.destination,
    required this.isDirectory,
    required this.size,
  });

  final String source;
  final String destination;
  final bool isDirectory;
  final int size;
}

/// Moves bytes between the local disk and any mounted remote source.
///
/// This is what makes copy and paste work across the boundary: the browser
/// hands over the same `List<String> sources` and `String destDir` it would
/// give the Rust core, and the engine works out — per item — whether that is
/// an upload, a download, a server-side copy inside one provider, or a relay
/// between two different ones. Nothing above it has to care.
class TransferEngine {
  TransferEngine({required CopyJobs jobs, RemoteHub? hub})
      : _jobs = jobs,
        _hub = hub ?? RemoteHub.instance;

  final CopyJobs _jobs;
  final RemoteHub _hub;

  /// 1 MiB: big enough that a fast link isn't dominated by per-chunk overhead,
  /// small enough that cancelling feels immediate.
  static const int _chunkSize = 1024 * 1024;

  /// True when this pair of paths needs the engine rather than the Rust core.
  static bool involvesRemote(Iterable<String> sources, String destDir) =>
      VPath.isRemote(destDir) || sources.any(VPath.isRemote);

  // ── public API ───────────────────────────────────────────────────────────

  Future<TransferReport> transfer({
    required List<String> sources,
    required String destDir,
    required bool move,
  }) async {
    if (sources.isEmpty) return const TransferReport.empty();

    final direction = _directionFor(sources.first, destDir);
    final jobId = _jobs.start(
      title: _titleFor(direction, destDir, move: move),
      direction: direction,
    );

    final completed = <String>[];
    final failures = <TransferFailure>[];
    var cancelled = false;

    try {
      final plan = await _plan(sources, destDir, jobId);
      final fileCount = plan.where((i) => !i.isDirectory).length;
      _jobs.update(
        jobId,
        filesTotal: fileCount,
        bytesTotal: plan.fold<int>(0, (sum, i) => sum + i.size),
      );

      var filesDone = 0;
      for (final item in plan) {
        if (_jobs.isCancelled(jobId)) {
          cancelled = true;
          break;
        }
        _jobs.update(jobId, current: item.source);
        try {
          if (item.isDirectory) {
            await _makeDirectory(item.destination);
          } else {
            await _copyFile(item, jobId);
            filesDone++;
            _jobs.update(jobId, filesDone: filesDone);
          }
          completed.add(item.source);
        } on _Cancelled {
          cancelled = true;
          break;
        } catch (e) {
          failures.add(TransferFailure(path: item.source, error: _describe(e)));
          _noteFailure(item.source, e);
        }
      }

      if (move && !cancelled && failures.isEmpty) {
        for (final source in sources) {
          try {
            await _deleteRecursively(source);
          } catch (e) {
            failures.add(TransferFailure(
              path: source,
              error: 'Copied, but the original couldn\'t be removed: '
                  '${_describe(e)}',
            ));
          }
        }
      }
    } on _Cancelled {
      cancelled = true;
    } catch (e) {
      failures.add(TransferFailure(path: destDir, error: _describe(e)));
      _noteFailure(destDir, e);
    }

    _jobs.finish(
      jobId,
      state: cancelled
          ? CopyJobState.cancelled
          : (failures.isEmpty ? CopyJobState.done : CopyJobState.failed),
      error: failures.isEmpty ? null : failures.first.error,
    );

    return TransferReport(
      completed: completed,
      failed: failures,
      cancelled: cancelled,
    );
  }

  /// Downloads a remote file to a local cache and returns its path.
  ///
  /// This is what lets a remote file be previewed, opened in another app, or
  /// fed to a workflow: everything downstream of the browser expects a real
  /// file, and a cloud object becomes one here rather than in twelve places.
  /// A file already cached with the same size is reused.
  Future<String> materialize(String remotePath) async {
    final fs = await _hub.fsForPath(remotePath);
    if (fs == null) return remotePath;

    final entry = await fs.stat(remotePath);
    final cacheDir = await _cacheDirFor(remotePath);
    final target = File(p.join(cacheDir.path, VPath.basename(remotePath)));
    if (entry != null &&
        entry.size > 0 &&
        await target.exists() &&
        await target.length() == entry.size) {
      return target.path;
    }

    final jobId = _jobs.start(
      title: 'Downloading ${VPath.basename(remotePath)}',
      direction: CopyDirection.download,
    );
    _jobs.update(
      jobId,
      filesTotal: 1,
      bytesTotal: entry?.size ?? 0,
      current: remotePath,
    );
    try {
      final download = await fs.download(remotePath);
      // A Google Doc arrives as a .docx / .xlsx, so the cached name is the
      // provider's, not the virtual path's.
      final out = download.name == null
          ? target
          : File(p.join(cacheDir.path, download.name!));
      await _writeLocal(out, download.stream, jobId);
      _jobs.finish(jobId, state: CopyJobState.done);
      _hub.reportSuccess(VPath.connectionOf(remotePath)!);
      return out.path;
    } on _Cancelled {
      _jobs.finish(jobId, state: CopyJobState.cancelled);
      rethrow;
    } catch (e) {
      _jobs.finish(jobId, state: CopyJobState.failed, error: _describe(e));
      _noteFailure(remotePath, e);
      rethrow;
    }
  }

  /// Drops the cached local copy of a remote file.
  ///
  /// Called after the editor writes a file back: the cache is validated by
  /// size, so an edit that happens to keep the length identical would
  /// otherwise be served stale the next time the file is previewed.
  Future<void> forgetCached(String remotePath) async {
    if (!VPath.isRemote(remotePath)) return;
    try {
      final dir = await _cacheDirFor(remotePath);
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        // The provider may have renamed it on the way down (a Google Doc
        // arrives as `name.docx`), so match on the stem too.
        if (name == VPath.basename(remotePath) ||
            p.basenameWithoutExtension(name) ==
                VPath.basenameWithoutExtension(remotePath)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // A cache that can't be cleaned is not worth failing a save over; the
      // size check catches the common case anyway.
    }
  }

  /// Where materialized copies live: one folder per connection inside the app's
  /// cache, so clearing a source's cache is a single directory delete.
  Future<Directory> _cacheDirFor(String remotePath) async {
    final base = await getApplicationSupportDirectory();
    final id = VPath.connectionOf(remotePath) ?? 'remote';
    final ref = VPath.parse(remotePath);
    final parentSegments =
        ref == null || ref.segments.length < 2 ? const <String>[] : ref.segments.sublist(0, ref.segments.length - 1);
    final dir = Directory(p.joinAll([
      base.path,
      'remote-cache',
      id,
      ...parentSegments.map(_safeSegment),
    ]));
    await dir.create(recursive: true);
    return dir;
  }

  /// Remote names are freer than local ones — a Drive folder can contain `/`
  /// in a display name, and Windows rejects half a dozen characters outright.
  static String _safeSegment(String segment) =>
      segment.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  // ── planning ─────────────────────────────────────────────────────────────

  Future<List<_PlanItem>> _plan(
    List<String> sources,
    String destDir,
    String jobId,
  ) async {
    final items = <_PlanItem>[];
    for (final source in sources) {
      if (_jobs.isCancelled(jobId)) throw const _Cancelled();
      if (VPath.isWithin(source, destDir)) {
        throw RemoteException(
          '"${VPath.basename(source)}" can\'t be copied into itself.',
        );
      }
      final info = await _statOf(source);
      if (info == null) {
        throw RemoteException(
          '"${VPath.basename(source)}" isn\'t there any more.',
          statusCode: 404,
        );
      }
      final destination =
          await _uniqueDestination(VPath.join(destDir, VPath.basename(source)));
      items.add(_PlanItem(
        source: source,
        destination: destination,
        isDirectory: info.isDirectory,
        size: info.size,
      ));
      if (!info.isDirectory) continue;

      await for (final child in _walk(source)) {
        if (_jobs.isCancelled(jobId)) throw const _Cancelled();
        final segments = _relativeSegments(source, child.path);
        if (segments.isEmpty) continue;
        items.add(_PlanItem(
          source: child.path,
          destination: segments.fold(destination, VPath.join),
          isDirectory: child.isDirectory,
          size: child.size,
        ));
      }
    }
    return items;
  }

  static List<String> _relativeSegments(String root, String child) {
    if (!child.startsWith(root)) return const [];
    return child
        .substring(root.length)
        .replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<({bool isDirectory, int size})?> _statOf(String path) async {
    if (VPath.isRemote(path)) {
      final fs = await _requireFs(path);
      final entry = await fs.stat(path);
      if (entry == null) return null;
      return (isDirectory: entry.isDirectory, size: entry.size);
    }
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return null;
    if (type == FileSystemEntityType.directory) {
      return (isDirectory: true, size: 0);
    }
    return (isDirectory: false, size: await File(path).length());
  }

  Stream<({String path, bool isDirectory, int size})> _walk(String root) async* {
    if (VPath.isRemote(root)) {
      final fs = await _requireFs(root);
      await for (final entry in fs.walk(root)) {
        yield (
          path: entry.path,
          isDirectory: entry.isDirectory,
          size: entry.size,
        );
      }
      return;
    }
    await for (final entity
        in Directory(root).list(recursive: true, followLinks: false)) {
      if (entity is Directory) {
        yield (path: entity.path, isDirectory: true, size: 0);
      } else if (entity is File) {
        int size;
        try {
          size = await entity.length();
        } catch (_) {
          size = 0;
        }
        yield (path: entity.path, isDirectory: false, size: size);
      }
    }
  }

  /// Never overwrite: a paste that lands on an existing name becomes
  /// "report (2).pdf", the same as a local paste through the Rust core.
  Future<String> _uniqueDestination(String path) async {
    if (VPath.isRemote(path)) {
      final fs = await _requireFs(path);
      return fs.uniquePath(path);
    }
    if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
      return path;
    }
    final dir = p.dirname(path);
    final name = p.basename(path);
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var n = 2; n < 1000; n++) {
      final candidate = p.join(dir, '$stem ($n)$ext');
      if (await FileSystemEntity.type(candidate) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw RemoteException('Couldn\'t find a free name for "$name".');
  }

  // ── moving the bytes ─────────────────────────────────────────────────────

  Future<void> _makeDirectory(String path) async {
    if (VPath.isRemote(path)) {
      final fs = await _requireFs(path);
      await fs.createDirectory(path);
      return;
    }
    await Directory(path).create(recursive: true);
  }

  Future<void> _copyFile(_PlanItem item, String jobId) async {
    final sourceRemote = VPath.isRemote(item.source);
    final destRemote = VPath.isRemote(item.destination);

    if (sourceRemote && destRemote) {
      final fs = await _requireFs(item.source);
      if (VPath.sameConnection(item.source, item.destination) &&
          fs.supportsServerSideCopy) {
        // The provider can move it internally: no reason to pull a gigabyte
        // through this machine and push it back.
        await fs.copyWithin(item.source, item.destination);
        _jobs.addBytes(jobId, item.size);
        _hub.reportSuccess(VPath.connectionOf(item.source)!);
        return;
      }
      // Two different providers: relay, counting bytes once as they pass.
      final download = await fs.download(item.source);
      final destFs = await _requireFs(item.destination);
      await destFs.upload(
        vpath: item.destination,
        data: _guard(download.stream, jobId),
        length: download.length >= 0 ? download.length : item.size,
      );
      return;
    }

    if (sourceRemote) {
      final fs = await _requireFs(item.source);
      final download = await fs.download(item.source);
      await _writeLocal(File(item.destination), download.stream, jobId);
      _hub.reportSuccess(VPath.connectionOf(item.source)!);
      return;
    }

    if (destRemote) {
      final file = File(item.source);
      final length = await file.length();
      final fs = await _requireFs(item.destination);
      await fs.upload(
        vpath: item.destination,
        data: _guard(file.openRead(), jobId),
        length: length,
      );
      _hub.reportSuccess(VPath.connectionOf(item.destination)!);
      return;
    }

    // Local to local. The Rust core normally owns this, but a mixed selection
    // (a local file and a cloud file pasted together) lands here too.
    await _writeLocal(
      File(item.destination),
      File(item.source).openRead(),
      jobId,
    );
  }

  /// Writes a stream to disk through a `.part` file, so an interrupted
  /// transfer never leaves something that looks like a finished download.
  Future<void> _writeLocal(
    File target,
    Stream<List<int>> source,
    String jobId,
  ) async {
    await target.parent.create(recursive: true);
    final part = File('${target.path}.notilus-part');
    final sink = part.openWrite();
    try {
      await sink.addStream(_guard(source, jobId));
      await sink.flush();
      await sink.close();
      await part.rename(target.path);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {
        // Already broken; the delete below is what matters.
      }
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  /// Passes bytes through, counting them and honouring a cancel request
  /// between chunks.
  Stream<List<int>> _guard(Stream<List<int>> source, String jobId) async* {
    var buffered = 0;
    await for (final chunk in source) {
      if (_jobs.isCancelled(jobId)) throw const _Cancelled();
      yield chunk;
      // Progress is reported per megabyte rather than per chunk: an HTTP
      // response can arrive in 8 KB pieces, and notifying the whole widget
      // tree that often would cost more than the copy.
      buffered += chunk.length;
      if (buffered >= _chunkSize) {
        _jobs.addBytes(jobId, buffered);
        buffered = 0;
      }
    }
    if (buffered > 0) _jobs.addBytes(jobId, buffered);
  }

  Future<void> _deleteRecursively(String path) async {
    if (VPath.isRemote(path)) {
      final fs = await _requireFs(path);
      final entry = await fs.stat(path);
      if (entry == null) return;
      await fs.delete(path, isDirectory: entry.isDirectory);
      return;
    }
    final type = await FileSystemEntity.type(path);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.notFound:
        return;
      default:
        await File(path).delete();
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  Future<RemoteFileSystem> _requireFs(String path) async {
    final fs = await _hub.fsForPath(path);
    if (fs == null) {
      throw RemoteException('"${VPath.basename(path)}" is not on a remote source.');
    }
    return fs;
  }

  /// Marks a source as unhealthy — but only for failures that say something
  /// about the source itself.
  ///
  /// A file that has been deleted, or a name that collides, is an ordinary
  /// outcome of a stale listing; painting the whole connection red for it
  /// would teach the user to ignore the light that matters when credentials
  /// really do expire.
  void _noteFailure(String path, Object error) {
    final id = VPath.connectionOf(path);
    if (id == null) return;
    if (error is RemoteException) {
      final code = error.statusCode;
      if (code != null && code < 500 && !error.isAuthFailure) return;
    }
    _hub.reportFailure(id, error);
  }

  static String _describe(Object error) {
    if (error is RemoteException) return error.message;
    if (error is FileSystemException) {
      return error.osError?.message ?? error.message;
    }
    return '$error';
  }

  CopyDirection _directionFor(String source, String destDir) {
    final from = VPath.isRemote(source);
    final to = VPath.isRemote(destDir);
    if (from && to) return CopyDirection.betweenRemotes;
    if (to) return CopyDirection.upload;
    if (from) return CopyDirection.download;
    return CopyDirection.local;
  }

  String _titleFor(CopyDirection direction, String destDir, {required bool move}) {
    final verb = move ? 'Moving' : 'Copying';
    final label = _hub.labelForPath(destDir);
    switch (direction) {
      case CopyDirection.upload:
      case CopyDirection.betweenRemotes:
        return '$verb to ${label ?? 'remote'}';
      case CopyDirection.download:
        return Platform.isMacOS ? '$verb to this Mac' : '$verb to this computer';
      case CopyDirection.local:
        return verb;
    }
  }
}

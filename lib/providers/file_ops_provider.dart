import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/file_entry.dart';
import '../services/native_core.dart';
import '../services/remote/remote_file_system.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';
import '../services/remote/transfer_engine.dart';
import '../services/thumbnails/leave_behind.dart';
import '../services/thumbnails/sidecar_thumbnails.dart';

/// What a pending clipboard payload will do when pasted.
enum ClipboardMode { copy, cut }

/// Files held for a paste, and whether pasting copies or moves them.
@immutable
class FileClipboard {
  const FileClipboard({required this.paths, required this.mode});

  final List<String> paths;
  final ClipboardMode mode;

  bool get isEmpty => paths.isEmpty;
}

/// A copy/move in flight, for the progress UI.
@immutable
class ActiveOperation {
  const ActiveOperation({
    required this.opId,
    required this.label,
    required this.filesDone,
    required this.filesTotal,
    required this.bytesDone,
    required this.bytesTotal,
    required this.current,
    this.cancelling = false,
  });

  final String opId;

  /// "Copying" / "Moving" — the verb shown in the dialog.
  final String label;
  final int filesDone;
  final int filesTotal;
  final int bytesDone;
  final int bytesTotal;

  /// Path currently being transferred.
  final String current;
  final bool cancelling;

  /// 0..1, or null while the size is still unknown (an indeterminate bar).
  double? get fraction {
    if (bytesTotal > 0) return (bytesDone / bytesTotal).clamp(0.0, 1.0);
    if (filesTotal > 0) return (filesDone / filesTotal).clamp(0.0, 1.0);
    return null;
  }

  ActiveOperation copyWith({
    int? filesDone,
    int? filesTotal,
    int? bytesDone,
    int? bytesTotal,
    String? current,
    bool? cancelling,
  }) =>
      ActiveOperation(
        opId: opId,
        label: label,
        filesDone: filesDone ?? this.filesDone,
        filesTotal: filesTotal ?? this.filesTotal,
        bytesDone: bytesDone ?? this.bytesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        current: current ?? this.current,
        cancelling: cancelling ?? this.cancelling,
      );
}

/// How an operation ended, for the caller to report.
@immutable
class OpResult {
  const OpResult({
    required this.completed,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });

  const OpResult.empty()
      : completed = const [],
        skipped = const [],
        failed = const [],
        cancelled = false;

  final List<String> completed;
  final List<String> skipped;
  final List<FailedItem> failed;
  final bool cancelled;

  bool get isSuccess => failed.isEmpty && !cancelled;
}

/// How a Quick Action ended, for the caller to report.
///
/// Separate from [OpResult] because a Quick Action *produces* something — an
/// archive, an extraction folder, a converted image — rather than moving
/// existing items around, and the UI wants to select what it produced.
@immutable
class QuickResult {
  const QuickResult({
    required this.produced,
    required this.failed,
    required this.cancelled,
  });

  const QuickResult.empty()
      : produced = const [],
        failed = const [],
        cancelled = false;

  QuickResult.error(String path, Object error)
      : produced = const [],
        failed = [FailedItem(path: path, error: '$error')],
        cancelled = false;

  final List<String> produced;
  final List<FailedItem> failed;
  final bool cancelled;

  bool get isSuccess => failed.isEmpty && !cancelled;

  /// The main thing created, for the browser to reveal afterwards.
  String? get first => produced.isEmpty ? null : produced.first;
}

/// Owns the file clipboard and runs copy/move/trash through the Rust core.
///
/// The Dart app previously had no copy, cut, paste or move at all — only
/// rename, duplicate-in-place and trash. Everything here is new capability
/// rather than a port.
///
/// All the heavy lifting (recursive walks, byte copying, cross-device moves)
/// happens in Rust; this class only holds UI state and forwards progress.
class FileOpsProvider extends ChangeNotifier {
  FileOpsProvider({NativeCore? core, TransferEngine? engine})
      : _core = core ?? NativeCore.instance,
        _engine = engine;

  final NativeCore _core;

  /// Moves bytes to and from mounted cloud sources. Null in tests and on the
  /// paths that never touch a remote — everything local still goes to Rust.
  final TransferEngine? _engine;

  FileClipboard? _clipboard;
  ActiveOperation? _active;

  FileClipboard? get clipboard => _clipboard;
  bool get hasClipboard => _clipboard != null && !_clipboard!.isEmpty;
  ActiveOperation? get activeOperation => _active;
  bool get isBusy => _active != null;

  /// Marks [paths] for copying.
  void copyToClipboard(List<String> paths) {
    if (paths.isEmpty) return;
    _clipboard = FileClipboard(paths: List.of(paths), mode: ClipboardMode.copy);
    notifyListeners();
  }

  /// Marks [paths] for moving. The files stay put until a paste happens.
  void cutToClipboard(List<String> paths) {
    if (paths.isEmpty) return;
    _clipboard = FileClipboard(paths: List.of(paths), mode: ClipboardMode.cut);
    notifyListeners();
  }

  void clearClipboard() {
    if (_clipboard == null) return;
    _clipboard = null;
    notifyListeners();
  }

  /// Pastes the clipboard into [destDir].
  ///
  /// A cut is consumed on success so the same files can't be moved twice; a
  /// copy is kept, so pasting into several folders in a row works.
  Future<OpResult> paste(String destDir) async {
    final board = _clipboard;
    if (board == null || board.isEmpty) return const OpResult.empty();

    final result = board.mode == ClipboardMode.cut
        ? await moveTo(board.paths, destDir)
        : await copyTo(board.paths, destDir);

    if (board.mode == ClipboardMode.cut && !result.cancelled) {
      clearClipboard();
    }
    return result;
  }

  /// Drops the thumbnails of files a move took out of their folder.
  ///
  /// A move is a delete as far as the folder left behind is concerned: the
  /// thumbnail there is keyed on a file that is no longer in it, so nothing
  /// will ever ask for it again. The destination folder makes its own the first
  /// time it is opened — and if the move was onto a share, that one is the copy
  /// every other machine gets for free.
  void _forgetMoved(List<String> moved) {
    if (moved.isEmpty) return;
    unawaited(SidecarThumbnails.instance.forget(moved).catchError((_) {}));
  }

  Future<OpResult> copyTo(List<String> sources, String destDir) =>
      _run(sources, destDir, isMove: false);

  Future<OpResult> moveTo(List<String> sources, String destDir) =>
      _run(sources, destDir, isMove: true);

  Future<OpResult> _run(
    List<String> sources,
    String destDir, {
    required bool isMove,
  }) async {
    if (sources.isEmpty) return const OpResult.empty();

    // Anything with a cloud source on either end goes to the transfer engine
    // instead of the Rust core, which only knows about local paths. It runs
    // outside the single-operation guard below on purpose: network transfers
    // are slow and independent of each other, and each gets its own row in the
    // progress HUD.
    final engine = _engine;
    if (engine != null && TransferEngine.involvesRemote(sources, destDir)) {
      final report = await engine.transfer(
        sources: sources,
        destDir: destDir,
        move: isMove,
      );
      if (isMove) _forgetMoved(report.completed);
      return OpResult(
        completed: report.completed,
        skipped: const [],
        failed: [
          for (final f in report.failed)
            FailedItem(path: f.path, error: f.error),
        ],
        cancelled: report.cancelled,
      );
    }

    if (_active != null) {
      // One operation at a time: two concurrent writes into the same folder
      // would race on collision-free naming.
      return const OpResult.empty();
    }

    final opId = _core.newOpId();
    _active = ActiveOperation(
      opId: opId,
      label: isMove ? 'Moving' : 'Copying',
      filesDone: 0,
      filesTotal: 0,
      bytesDone: 0,
      bytesTotal: 0,
      current: '',
    );
    notifyListeners();

    try {
      final stream = isMove
          ? _core.move(sources: sources, destDir: destDir, opId: opId)
          : _core.copy(sources: sources, destDir: destDir, opId: opId);

      OpOutcome? outcome;
      await for (final event in stream) {
        switch (event) {
          case OpEvent_Progress(:final field0):
            _active = _active?.copyWith(
              filesDone: field0.filesDone.toInt(),
              filesTotal: field0.filesTotal.toInt(),
              bytesDone: field0.bytesDone.toInt(),
              bytesTotal: field0.bytesTotal.toInt(),
              current: field0.current,
            );
            notifyListeners();
          case OpEvent_Done(:final field0):
            outcome = field0;
        }
      }

      if (outcome == null) return const OpResult.empty();
      if (isMove) _forgetMoved(outcome.completed);
      return OpResult(
        completed: outcome.completed,
        skipped: outcome.skipped,
        failed: outcome.failed,
        cancelled: outcome.cancelled,
      );
    } catch (e) {
      return OpResult(
        completed: const [],
        skipped: const [],
        failed: [FailedItem(path: destDir, error: '$e')],
        cancelled: false,
      );
    } finally {
      _active = null;
      notifyListeners();
    }
  }

  // ── quick actions ────────────────────────────────────────────────────────

  /// Zips [sources] into [destDir] as [archiveName].
  Future<QuickResult> compress({
    required List<String> sources,
    required String destDir,
    required String archiveName,
  }) {
    if (sources.isEmpty) return Future.value(const QuickResult.empty());
    return _runQuick(
      label: 'Compressing',
      destDir: destDir,
      start: (opId) => _core.compress(
        sources: sources,
        destDir: destDir,
        archiveName: archiveName,
        opId: opId,
      ),
    );
  }

  /// Unpacks the archive at [path] into [destDir].
  Future<QuickResult> extract({
    required String path,
    required String destDir,
    bool intoSubfolder = true,
  }) =>
      _runQuick(
        label: 'Extracting',
        destDir: destDir,
        start: (opId) => _core.extractArchive(
          path: path,
          destDir: destDir,
          opId: opId,
          intoSubfolder: intoSubfolder,
        ),
      );

  /// Shared driver for the streaming Quick Actions: same one-at-a-time guard,
  /// same [ActiveOperation] the copy/move progress bar already renders, so a
  /// zip in flight looks and cancels exactly like a copy in flight.
  Future<QuickResult> _runQuick({
    required String label,
    required String destDir,
    required Stream<QuickEvent> Function(String opId) start,
  }) async {
    if (_active != null) return const QuickResult.empty();

    final opId = _core.newOpId();
    _active = ActiveOperation(
      opId: opId,
      label: label,
      filesDone: 0,
      filesTotal: 0,
      bytesDone: 0,
      bytesTotal: 0,
      current: '',
    );
    notifyListeners();

    try {
      QuickOutcome? outcome;
      await for (final event in start(opId)) {
        switch (event) {
          case QuickEvent_Progress(:final field0):
            _active = _active?.copyWith(
              filesDone: field0.filesDone.toInt(),
              filesTotal: field0.filesTotal.toInt(),
              bytesDone: field0.bytesDone.toInt(),
              bytesTotal: field0.bytesTotal.toInt(),
              current: field0.current,
            );
            notifyListeners();
          case QuickEvent_Done(:final field0):
            outcome = field0;
        }
      }
      if (outcome == null) {
        // A Quick Action that fails outright in Rust ends its stream without a
        // Done event: flutter_rust_bridge delivers the `Err` on the call's own
        // future rather than into the sink, so an empty stream is the only
        // signal that reaches here. Reporting it as a failure keeps a corrupt
        // archive or an unwritable folder from looking like a silent success.
        return QuickResult.error(destDir, 'The operation didn\'t complete.');
      }
      return QuickResult(
        produced: outcome.produced,
        failed: outcome.failed,
        cancelled: outcome.cancelled,
      );
    } catch (e) {
      return QuickResult.error(destDir, e);
    } finally {
      _active = null;
      notifyListeners();
    }
  }

  /// Walks [path] and reports what it holds. Returns null if another operation
  /// is already running, or if the walk failed outright.
  ///
  /// Shares the progress bar with everything else here — a home-directory walk
  /// is long enough that the user needs both a sign of life and a way out.
  Future<FolderStats?> folderStats(String path) async {
    if (_active != null) return null;

    final opId = _core.newOpId();
    _active = ActiveOperation(
      opId: opId,
      label: 'Calculating size',
      filesDone: 0,
      filesTotal: 0,
      bytesDone: 0,
      bytesTotal: 0,
      current: '',
    );
    notifyListeners();

    try {
      FolderStats? stats;
      await for (final event in _core.folderStats(path: path, opId: opId)) {
        switch (event) {
          case StatsEvent_Progress(:final field0):
            _active = _active?.copyWith(
              filesDone: field0.filesDone.toInt(),
              bytesDone: field0.bytesDone.toInt(),
              current: field0.current,
            );
            notifyListeners();
          case StatsEvent_Done(:final field0):
            stats = field0;
        }
      }
      return stats;
    } catch (_) {
      return null;
    } finally {
      _active = null;
      notifyListeners();
    }
  }

  /// Asks the running operation to stop. Rust polls the flag between files and
  /// between chunks, so a large copy aborts promptly and its partial
  /// destination is removed.
  Future<void> cancelActive() async {
    final active = _active;
    if (active == null || active.cancelling) return;
    _active = active.copyWith(cancelling: true);
    notifyListeners();
    await _core.cancel(active.opId);
  }

  /// Moves [paths] to the platform recycle bin.
  ///
  /// Cloud sources have their own idea of a recycle bin — Drive trashes,
  /// S3 deletes (or versions, if the bucket is versioned) — so a remote path
  /// is handed to its provider rather than to the local trash.
  Future<TrashOutcome> trash(List<String> paths) => _delete(paths);

  /// Deletes without going through the recycle bin. The caller must have
  /// confirmed this with the user.
  Future<TrashOutcome> deleteForever(List<String> paths) =>
      _delete(paths, permanent: true);

  Future<TrashOutcome> _delete(
    List<String> paths, {
    bool permanent = false,
  }) async {
    final local = [for (final path in paths) if (!VPath.isRemote(path)) path];
    final remote = [for (final path in paths) if (VPath.isRemote(path)) path];

    final trashed = <String>[];
    final failed = <FailedItem>[];

    if (local.isNotEmpty) {
      final outcome = permanent
          ? await _core.deletePermanently(local)
          : await _core.moveToTrash(local);
      trashed.addAll(outcome.trashed);
      failed.addAll(outcome.failed);
    }

    for (final path in remote) {
      try {
        final fs = await RemoteHub.instance.fsFor(VPath.connectionOf(path)!);
        final entry = await fs.stat(path);
        await fs.delete(path, isDirectory: entry?.isDirectory ?? false);
        trashed.add(path);
      } catch (e) {
        failed.add(FailedItem(
          path: path,
          error: e is RemoteException ? e.message : '$e',
        ));
      }
    }

    if (remote.isNotEmpty) notifyListeners();
    // A thumbnail is a readable picture of the file, so one left behind is a
    // copy of something the user just deleted — and on a share, a copy the
    // rest of the network can still open. Only the files that actually went
    // are named here.
    if (trashed.isNotEmpty) {
      unawaited(
        SidecarThumbnails.instance.forget(trashed).catchError((_) {}),
      );
    }
    return TrashOutcome(trashed: trashed, failed: failed);
  }

  /// A real local file for [path], downloading it first when it lives on a
  /// remote source.
  ///
  /// Preview, "Open With", the workflows and the Rust quick actions all need a
  /// path they can `open()`. Rather than teach each of them about cloud
  /// storage, a remote file becomes a local one here — cached, so opening the
  /// same file twice costs one download.
  Future<String> localCopyOf(String path) async {
    if (!VPath.isRemote(path)) return path;
    final engine = _engine;
    if (engine == null) {
      throw RemoteException('Remote sources are not available.');
    }
    return engine.materialize(path);
  }

  /// The same as [localCopyOf], as a [FileEntry] the rest of the app can pass
  /// around — the chat panel, the workflow runner and the preview all take an
  /// entry, not a path.
  Future<FileEntry> localEntryFor(FileEntry entry) async {
    if (!VPath.isRemote(entry.path)) return entry;
    final path = await localCopyOf(entry.path);
    final stat = await File(path).stat();
    // The bytes are here now, which is the only moment a cloud file can be
    // thumbnailed without downloading it on purpose. Leaving one in the
    // source's own `.thumbs` is what means nobody — on this machine or any
    // other — has to open this file again to see what it is.
    unawaited(leaveThumbnailBeside(entry, path));
    return FileEntry(
      path: path,
      name: p.basename(path),
      isDirectory: false,
      size: stat.size,
      modified: stat.modified,
    );
  }

  /// Forgets any downloaded copy of a remote file, after something wrote to
  /// the original.
  Future<void> forgetCachedCopy(String path) async {
    if (!VPath.isRemote(path)) return;
    await _engine?.forgetCached(path);
  }

  /// Creates an empty file in [dir], local or remote. Returns its path.
  Future<String> createFileIn(String dir, String name) async {
    if (!VPath.isRemote(dir)) return _core.createFile(dir, name);
    final fs = await RemoteHub.instance.fsFor(VPath.connectionOf(dir)!);
    final target = await fs.uniquePath(VPath.join(dir, name));
    await fs.upload(
      vpath: target,
      data: const Stream<List<int>>.empty(),
      length: 0,
    );
    return target;
  }

  /// A shareable URL for a remote item, or null when the provider has none.
  Future<String?> shareLinkFor(String path) async {
    if (!VPath.isRemote(path)) return null;
    final fs = await RemoteHub.instance.fsFor(VPath.connectionOf(path)!);
    return fs.shareLink(path);
  }

  /// Renames a single item, wherever it lives. Returns the new path.
  Future<String> renameEntry(String path, String newName) async {
    final renamed = !VPath.isRemote(path)
        ? await _core.rename(path, newName)
        : await (await RemoteHub.instance.fsFor(VPath.connectionOf(path)!))
            .rename(path, newName);
    // The thumbnail is keyed on the old name, so it is now unreachable — an
    // orphan on a shared source that nothing will ever look for again. The new
    // name gets its own the next time the folder is opened.
    unawaited(SidecarThumbnails.instance.forget([path]).catchError((_) {}));
    return renamed;
  }
}

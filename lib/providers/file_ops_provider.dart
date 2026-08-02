import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/native_core.dart';

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

/// Owns the file clipboard and runs copy/move/trash through the Rust core.
///
/// The Dart app previously had no copy, cut, paste or move at all — only
/// rename, duplicate-in-place and trash. Everything here is new capability
/// rather than a port.
///
/// All the heavy lifting (recursive walks, byte copying, cross-device moves)
/// happens in Rust; this class only holds UI state and forwards progress.
class FileOpsProvider extends ChangeNotifier {
  FileOpsProvider({NativeCore? core}) : _core = core ?? NativeCore.instance;

  final NativeCore _core;

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
  Future<TrashOutcome> trash(List<String> paths) =>
      _core.moveToTrash(paths);

  /// Deletes without going through the recycle bin. The caller must have
  /// confirmed this with the user.
  Future<TrashOutcome> deleteForever(List<String> paths) =>
      _core.deletePermanently(paths);
}

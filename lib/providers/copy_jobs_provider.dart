import 'dart:async';

import 'package:flutter/foundation.dart';

/// Where a job's bytes are going. Only used to label and ice the UI — the
/// engine treats all four the same.
enum CopyDirection { upload, download, betweenRemotes, local }

enum CopyJobState { running, done, failed, cancelled }

/// One copy or move in flight — or one that has just finished and is still
/// being shown.
@immutable
class CopyJob {
  const CopyJob({
    required this.id,
    required this.title,
    required this.direction,
    required this.startedAt,
    this.state = CopyJobState.running,
    this.filesTotal = 0,
    this.filesDone = 0,
    this.bytesTotal = 0,
    this.bytesDone = 0,
    this.current = '',
    this.error,
    this.cancelRequested = false,
  });

  final String id;

  /// "Uploading to Work S3" — the verb plus where it's going.
  final String title;
  final CopyDirection direction;
  final DateTime startedAt;
  final CopyJobState state;
  final int filesTotal;
  final int filesDone;
  final int bytesTotal;
  final int bytesDone;

  /// Name of the file being moved right now.
  final String current;
  final String? error;
  final bool cancelRequested;

  bool get isRunning => state == CopyJobState.running;

  /// 0..1, or null while the size is still being worked out — the same
  /// contract the local file-op bar already uses for its indeterminate sweep.
  double? get fraction {
    if (bytesTotal > 0) return (bytesDone / bytesTotal).clamp(0.0, 1.0);
    if (filesTotal > 0) return (filesDone / filesTotal).clamp(0.0, 1.0);
    return null;
  }

  /// Bytes per second averaged over the whole job. Null until there is enough
  /// of a sample for the number to mean anything.
  double? get rate {
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    if (elapsed < 700 || bytesDone <= 0) return null;
    return bytesDone * 1000 / elapsed;
  }

  /// Seconds left at the current rate, or null when it can't be estimated.
  int? get secondsRemaining {
    final r = rate;
    if (r == null || r <= 0 || bytesTotal <= 0) return null;
    final left = bytesTotal - bytesDone;
    if (left <= 0) return 0;
    return (left / r).round();
  }

  CopyJob copyWith({
    CopyJobState? state,
    int? filesTotal,
    int? filesDone,
    int? bytesTotal,
    int? bytesDone,
    String? current,
    String? error,
    bool? cancelRequested,
  }) =>
      CopyJob(
        id: id,
        title: title,
        direction: direction,
        startedAt: startedAt,
        state: state ?? this.state,
        filesTotal: filesTotal ?? this.filesTotal,
        filesDone: filesDone ?? this.filesDone,
        bytesTotal: bytesTotal ?? this.bytesTotal,
        bytesDone: bytesDone ?? this.bytesDone,
        current: current ?? this.current,
        error: error ?? this.error,
        cancelRequested: cancelRequested ?? this.cancelRequested,
      );
}

/// The list of copy/move jobs the progress HUD renders.
///
/// Unlike the local Rust operations — which are deliberately one-at-a-time,
/// because two concurrent writes into one folder would race on collision-free
/// naming — network transfers are expected to overlap: an upload to S3 and a
/// download from Drive have nothing to do with each other, and making the user
/// wait for one before starting the other would be the wrong kind of safety.
class CopyJobs extends ChangeNotifier {
  final List<CopyJob> _jobs = [];
  final Set<String> _cancelled = {};
  final Map<String, Timer> _reapers = {};
  int _counter = 0;

  /// How long a finished job stays on screen. Long enough to read, short
  /// enough not to become furniture. Failures are never auto-dismissed.
  static const Duration _lingerAfterSuccess = Duration(seconds: 5);

  List<CopyJob> get jobs => List.unmodifiable(_jobs);
  bool get hasJobs => _jobs.isNotEmpty;
  Iterable<CopyJob> get running => _jobs.where((j) => j.isRunning);
  bool get isBusy => running.isNotEmpty;

  CopyJob? byId(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  String start({required String title, required CopyDirection direction}) {
    final id = 'copy-${_counter++}';
    _jobs.add(CopyJob(
      id: id,
      title: title,
      direction: direction,
      startedAt: DateTime.now(),
    ));
    notifyListeners();
    return id;
  }

  void update(
    String id, {
    int? filesTotal,
    int? filesDone,
    int? bytesTotal,
    int? bytesDone,
    String? current,
  }) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0) return;
    _jobs[index] = _jobs[index].copyWith(
      filesTotal: filesTotal,
      filesDone: filesDone,
      bytesTotal: bytesTotal,
      bytesDone: bytesDone,
      current: current,
    );
    notifyListeners();
  }

  /// Adds to the running byte count. The transfer engine reports deltas
  /// because it sees chunks, not totals.
  void addBytes(String id, int delta) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0) return;
    _jobs[index] =
        _jobs[index].copyWith(bytesDone: _jobs[index].bytesDone + delta);
    notifyListeners();
  }

  void finish(String id, {required CopyJobState state, String? error}) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0) return;
    _jobs[index] = _jobs[index].copyWith(state: state, error: error);
    _cancelled.remove(id);
    notifyListeners();
    if (state == CopyJobState.failed) return;
    _reapers[id]?.cancel();
    _reapers[id] = Timer(_lingerAfterSuccess, () => dismiss(id));
  }

  /// Asks a job to stop. The engine checks between chunks, so a big file
  /// aborts within a chunk rather than at the end of the file.
  void cancel(String id) {
    final index = _jobs.indexWhere((j) => j.id == id);
    if (index < 0) return;
    _cancelled.add(id);
    _jobs[index] = _jobs[index].copyWith(cancelRequested: true);
    notifyListeners();
  }

  bool isCancelled(String id) => _cancelled.contains(id);

  void dismiss(String id) {
    _reapers.remove(id)?.cancel();
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.id == id);
    if (_jobs.length != before) notifyListeners();
  }

  /// Clears everything that has finished, leaving running jobs alone.
  void dismissFinished() {
    final before = _jobs.length;
    _jobs.removeWhere((j) => !j.isRunning);
    if (_jobs.length != before) notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _reapers.values) {
      timer.cancel();
    }
    _reapers.clear();
    super.dispose();
  }
}

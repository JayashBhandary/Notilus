import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Phase 6 — the file-transfer protocol that rides on top of an open WebRTC
/// DataChannel. Deliberately transport-agnostic: it talks to a [TransferConduit]
/// (text + binary frames, backpressure) rather than to `RTCDataChannel`
/// directly, so the chunking / sha256 / reassembly logic can be unit-tested with
/// an in-memory conduit pair (flutter_webrtc is native and can't run under
/// `flutter test`). The real adapter lives in `rtc_conduit.dart`.
///
/// Wire format on a single ordered channel:
///   text  {v,t:'file-header', index,total,name,size,sha256}
///   binary … raw chunks (<= [FileSender.chunkSize]) …
///   text  {v,t:'file-done', index}
///   … repeat per file …
///   text  {v,t:'batch-done'}          (or {t:'cancel'} if aborted)
/// Ordering across text/binary is guaranteed because it's one ordered SCTP
/// stream, so a header always precedes its chunks and a done always follows.

// ── wire message types ──────────────────────────────────────────────────────
const String kFileHeader = 'file-header';
const String kFileDone = 'file-done';
const String kBatchDone = 'batch-done';
const String kCancel = 'cancel';

/// The transport a [FileSender]/[FileReceiver] drives. One implementation wraps
/// a live `RTCDataChannel`; tests use a paired in-memory fake.
abstract class TransferConduit {
  Future<void> sendText(String text);
  Future<void> sendBinary(Uint8List bytes);

  /// Bytes queued but not yet handed to the network (for backpressure).
  int get bufferedAmount;

  /// Fires [onBufferedLow] once the buffered amount drops below this.
  set bufferedAmountLowThreshold(int bytes);

  set onText(void Function(String text)? cb);
  set onBinary(void Function(Uint8List bytes)? cb);
  set onBufferedLow(void Function()? cb);

  Future<void> close();
}

/// Raised when a transfer makes no progress for [FileSender.stallTimeout] /
/// [FileReceiver.stallTimeout] — the peer vanished mid-flight.
class TransferStalled implements Exception {
  TransferStalled(this.message);
  final String message;
  @override
  String toString() => 'TransferStalled: $message';
}

enum TransferStatus { pending, active, done, failed, cancelled }

/// Progress for a single file within a batch. [bytes] is what has crossed the
/// wire so far; [savedPath] is set on the receiver once committed to disk.
class FileTransferProgress {
  FileTransferProgress({
    required this.index,
    required this.name,
    required this.size,
  });

  final int index;
  String name;
  int size;
  int bytes = 0;
  TransferStatus status = TransferStatus.pending;
  String? savedPath;
  String? error;

  double get fraction {
    if (status == TransferStatus.done) return 1;
    if (size <= 0) return 0;
    return (bytes / size).clamp(0.0, 1.0);
  }
}

/// Progress for a whole transfer (one request = one batch of files).
class BatchProgress {
  BatchProgress({required this.sending, required this.files});

  /// True when we're the sender; false when receiving.
  final bool sending;
  final List<FileTransferProgress> files;
  TransferStatus status = TransferStatus.pending;
  int currentIndex = 0;
  String? error;

  int get fileCount => files.length;
  int get totalBytes => files.fold(0, (a, f) => a + f.size);
  int get transferredBytes => files.fold(0, (a, f) => a + f.bytes);

  double get fraction {
    final total = totalBytes;
    if (total <= 0) return status == TransferStatus.done ? 1 : 0;
    return (transferredBytes / total).clamp(0.0, 1.0);
  }

  bool get isFinished =>
      status == TransferStatus.done ||
      status == TransferStatus.failed ||
      status == TransferStatus.cancelled;
}

/// A local file queued to send.
class OutgoingFile {
  const OutgoingFile({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;

  /// Reads name + size off disk. Throws if the file is missing.
  factory OutgoingFile.forPath(String path) {
    final f = File(path);
    return OutgoingFile(
      path: path,
      name: p.basename(path),
      size: f.lengthSync(),
    );
  }
}

/// Streams a batch of files over [conduit] with `bufferedAmount` backpressure.
class FileSender {
  FileSender({
    required this.conduit,
    required this.files,
    this.onProgress,
    this.chunkSize = 16 * 1024,
    this.highWater = 1024 * 1024,
    this.lowWater = 256 * 1024,
    this.stallTimeout = const Duration(seconds: 30),
  });

  final TransferConduit conduit;
  final List<OutgoingFile> files;
  final void Function(BatchProgress progress)? onProgress;
  final int chunkSize;
  final int highWater;
  final int lowWater;

  /// Fail the batch if the send buffer refuses to drain for this long.
  final Duration stallTimeout;

  bool _cancelled = false;
  Completer<void>? _drainWaiter;

  /// Sends all [files] and resolves with the final progress. Never throws for a
  /// per-file error — it records it on the progress and keeps the channel sane.
  Future<BatchProgress> send() async {
    final progress = BatchProgress(
      sending: true,
      files: [
        for (var i = 0; i < files.length; i++)
          FileTransferProgress(
            index: i,
            name: files[i].name,
            size: files[i].size,
          ),
      ],
    );
    progress.status = TransferStatus.active;

    conduit.bufferedAmountLowThreshold = lowWater;
    conduit.onBufferedLow = () {
      final w = _drainWaiter;
      _drainWaiter = null;
      if (w != null && !w.isCompleted) w.complete();
    };

    try {
      for (var i = 0; i < files.length && !_cancelled; i++) {
        progress.currentIndex = i;
        await _sendOne(files[i], progress.files[i]);
        _report(progress);
      }
      if (_cancelled) {
        await _safeSend(jsonEncode({'v': 1, 't': kCancel}));
        progress.status = TransferStatus.cancelled;
      } else {
        await conduit.sendText(jsonEncode({'v': 1, 't': kBatchDone}));
        progress.status = TransferStatus.done;
      }
    } catch (e) {
      progress.status = TransferStatus.failed;
      progress.error = '$e';
      await _safeSend(jsonEncode({'v': 1, 't': kCancel, 'reason': 'error'}));
    }
    _report(progress);
    return progress;
  }

  /// Requests an early stop; the current [send] loop tears down cleanly.
  void cancel() {
    _cancelled = true;
    final w = _drainWaiter;
    _drainWaiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _sendOne(OutgoingFile file, FileTransferProgress fp) async {
    fp.status = TransferStatus.active;
    final sha = await _sha256OfFile(file.path);
    if (_cancelled) return;

    await conduit.sendText(jsonEncode({
      'v': 1,
      't': kFileHeader,
      'index': fp.index,
      'total': files.length,
      'name': file.name,
      'size': file.size,
      'sha256': sha,
    }));

    await for (final data in File(file.path).openRead()) {
      if (_cancelled) return;
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      var offset = 0;
      while (offset < bytes.length) {
        if (_cancelled) return;
        final end = math.min(offset + chunkSize, bytes.length);
        await _drain();
        if (_cancelled) return;
        await conduit.sendBinary(Uint8List.sublistView(bytes, offset, end));
        fp.bytes += end - offset;
        offset = end;
        _report();
      }
    }
    if (_cancelled) return;
    fp.status = TransferStatus.done;
    await conduit.sendText(jsonEncode({'v': 1, 't': kFileDone, 'index': fp.index}));
  }

  /// Blocks while the send buffer is above [highWater], waking on the conduit's
  /// buffered-low event (with a poll fallback so we never wedge). Throws
  /// [TransferStalled] if it stays full past [stallTimeout] — a dead peer.
  Future<void> _drain() async {
    final start = DateTime.now();
    while (!_cancelled && conduit.bufferedAmount > highWater) {
      if (DateTime.now().difference(start) > stallTimeout) {
        throw TransferStalled('send buffer not draining');
      }
      final c = _drainWaiter = Completer<void>();
      await Future.any<void>([
        c.future,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
      _drainWaiter = null;
    }
  }

  Future<void> _safeSend(String text) async {
    try {
      await conduit.sendText(text);
    } catch (_) {}
  }

  BatchProgress? _lastReported;
  void _report([BatchProgress? p]) {
    final prog = p ?? _lastReported;
    if (prog == null) return;
    _lastReported = prog;
    onProgress?.call(prog);
  }

  static Future<String> _sha256OfFile(String path) async {
    final out = _DigestSink();
    final input = sha256.startChunkedConversion(out);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return out.value.toString();
  }
}

/// Minimal [Sink] capturing the single [Digest] from a chunked sha256
/// conversion — avoids depending on package:convert's `AccumulatorSink`.
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Reassembles an incoming batch, streaming each file to a `.part` on disk,
/// verifying sha256, then committing to a collision-free final name.
class FileReceiver {
  FileReceiver({
    required this.conduit,
    required this.destDir,
    this.manifest = const [],
    this.onProgress,
    this.stallTimeout = const Duration(seconds: 30),
  });

  final TransferConduit conduit;
  final String destDir;

  /// Fail (and clean up the partial) if no frame arrives for this long.
  final Duration stallTimeout;

  /// Optional up-front (name,size) list from the accepted request, so overall
  /// progress has a correct total before headers arrive. Extra files (or a
  /// missing manifest) are handled by adding entries as headers land.
  final List<({String name, int size})> manifest;
  final void Function(BatchProgress progress)? onProgress;

  final Completer<BatchProgress> _done = Completer<BatchProgress>();
  late final BatchProgress _progress = BatchProgress(
    sending: false,
    files: [
      for (var i = 0; i < manifest.length; i++)
        FileTransferProgress(
          index: i,
          name: manifest[i].name,
          size: manifest[i].size,
        ),
    ],
  );

  // Serialize all inbound frames so an async file-done can't race a following
  // header/chunk (callbacks fire in delivery order; this keeps the work in it).
  Future<void> _tail = Future<void>.value();

  IOSink? _sink;
  File? _partFile;
  FileTransferProgress? _current;
  String? _expectedSha;
  _DigestSink? _digestOut;
  ByteConversionSink? _digestIn;
  bool _closed = false;
  Timer? _watchdog;

  Future<BatchProgress> receive() {
    _progress.status = TransferStatus.active;
    _kick();
    conduit.onText = (s) => _enqueue(() => _handleText(s));
    conduit.onBinary = (b) => _enqueue(() => _handleBinary(b));
    return _done.future;
  }

  /// (Re)arms the idle watchdog; fires a stall failure if it isn't kicked again
  /// before [stallTimeout].
  void _kick() {
    _watchdog?.cancel();
    if (_closed) return;
    _watchdog = Timer(stallTimeout, () {
      _enqueue(() async {
        await _abortPartial();
        _finish(TransferStatus.failed,
            error: 'Transfer stalled (peer unresponsive)');
      });
    });
  }

  /// Local abort (user cancelled on the receiving end).
  Future<void> cancel() async {
    _enqueue(() async {
      try {
        await conduit.sendText(jsonEncode({'v': 1, 't': kCancel}));
      } catch (_) {}
      await _abortPartial();
      _finish(TransferStatus.cancelled);
    });
    await _done.future;
  }

  void _enqueue(Future<void> Function() task) {
    _kick(); // any inbound activity resets the idle watchdog
    _tail = _tail.then((_) {
      if (_closed) return null;
      return task();
    }).catchError((Object e) {
      _current?.error = '$e';
      _abortPartial();
      _finish(TransferStatus.failed, error: '$e');
    });
  }

  Future<void> _handleText(String s) async {
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(s);
      if (decoded is! Map) return;
      msg = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (msg['t']) {
      case kFileHeader:
        await _startFile(msg);
        break;
      case kFileDone:
        await _finishFile();
        break;
      case kBatchDone:
        _finish(_progress.files.any((f) => f.status == TransferStatus.failed)
            ? TransferStatus.failed
            : TransferStatus.done);
        break;
      case kCancel:
        await _abortPartial();
        _finish(TransferStatus.cancelled);
        break;
    }
  }

  Future<void> _handleBinary(Uint8List bytes) async {
    final cur = _current;
    final sink = _sink;
    if (cur == null || sink == null) return;
    sink.add(bytes);
    _digestIn?.add(bytes);
    cur.bytes += bytes.length;
    _report();
  }

  Future<void> _startFile(Map<String, dynamic> msg) async {
    // A stray header mid-file: close out the old partial first.
    if (_sink != null) await _abortPartial();

    final index = _asInt(msg['index']) ?? _progress.files.length;
    final name = _safeName(msg['name']);
    final size = _asInt(msg['size']) ?? 0;
    _expectedSha = msg['sha256'] as String?;

    FileTransferProgress fp;
    if (index >= 0 && index < _progress.files.length) {
      fp = _progress.files[index];
      fp.name = name;
      if (size > 0) fp.size = size;
    } else {
      fp = FileTransferProgress(index: index, name: name, size: size);
      _progress.files.add(fp);
    }
    fp.status = TransferStatus.active;
    fp.bytes = 0;
    _current = fp;
    _progress.currentIndex = _progress.files.indexOf(fp);

    await Directory(destDir).create(recursive: true);
    _partFile = File(p.join(destDir, '$name.part'));
    _sink = _partFile!.openWrite();
    _digestOut = _DigestSink();
    _digestIn = sha256.startChunkedConversion(_digestOut!);
    _report();
  }

  Future<void> _finishFile() async {
    final cur = _current;
    final sink = _sink;
    final part = _partFile;
    if (cur == null || sink == null || part == null) return;

    await sink.flush();
    await sink.close();
    _digestIn?.close();
    final got = _digestOut?.value?.toString();

    if (_expectedSha != null && got != _expectedSha) {
      cur.status = TransferStatus.failed;
      cur.error = 'Integrity check failed';
      await _deleteQuietly(part);
    } else {
      final finalPath = await _uniquePath(p.join(destDir, cur.name));
      await part.rename(finalPath);
      cur.status = TransferStatus.done;
      cur.savedPath = finalPath;
      cur.bytes = cur.size;
    }
    _resetFileState();
    _report();
  }

  Future<void> _abortPartial() async {
    final sink = _sink;
    final part = _partFile;
    final cur = _current;
    try {
      await sink?.close();
    } catch (_) {}
    if (part != null) await _deleteQuietly(part);
    if (cur != null && cur.status == TransferStatus.active) {
      cur.status = TransferStatus.cancelled;
    }
    _resetFileState();
  }

  void _resetFileState() {
    _sink = null;
    _partFile = null;
    _current = null;
    _expectedSha = null;
    _digestIn = null;
    _digestOut = null;
  }

  void _finish(TransferStatus status, {String? error}) {
    if (_done.isCompleted) return;
    _closed = true;
    _watchdog?.cancel();
    _watchdog = null;
    _progress.status = status;
    if (error != null) _progress.error = error;
    _report();
    _done.complete(_progress);
  }

  void _report() => onProgress?.call(_progress);

  /// Adds " (n)" before the extension until the path is free.
  static Future<String> _uniquePath(String path) async {
    if (!await File(path).exists()) return path;
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    for (var n = 1;; n++) {
      final candidate = p.join(dir, '$stem ($n)$ext');
      if (!await File(candidate).exists()) return candidate;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Strips any directory component so a hostile header can't escape [destDir].
  static String _safeName(Object? raw) {
    final name = p.basename('${raw ?? ''}'.replaceAll('\\', '/'));
    return (name.isEmpty || name == '.' || name == '..') ? 'file' : name;
  }

  static int? _asInt(Object? v) =>
      v is int ? v : int.tryParse('${v ?? ''}');
}

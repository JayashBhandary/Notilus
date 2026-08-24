import 'dart:async';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../src/rust/api/archive.dart' as rust_archive;
import '../src/rust/api/bridge.dart' as rust;
import '../src/rust/api/dedupe.dart' as rust_dedupe;
import '../src/rust/api/email.dart' as rust_email;
import '../src/rust/api/fileops.dart' as rust_fileops;
import '../src/rust/api/listing.dart' as rust_listing;
import '../src/rust/api/quick.dart' as rust_quick;
import '../src/rust/api/search.dart' as rust_search;
import '../src/rust/api/sharing.dart' as rust_sharing;
import '../src/rust/api/thumbnail.dart' as rust_thumbnail;
import '../src/rust/api/trash.dart' as rust_trash;
import '../src/rust/frb_generated.dart';

// Re-exported so callers import one file rather than reaching into
// `lib/src/rust` directly. `SortField` is deliberately *not* re-exported:
// `BrowserProvider` already owns an enum by that name, and shadowing it here
// would make every call site ambiguous.
export '../src/rust/api/archive.dart' show ArchiveEntry;
// The `*_Progress` / `*_Done` variants are the freezed union members callers
// pattern-match on, so they have to come along with the sealed parent.
export '../src/rust/api/bridge.dart'
    show
        OpEvent,
        OpEvent_Done,
        OpEvent_Progress,
        ScanEvent,
        ScanEvent_Done,
        ScanEvent_Progress,
        QuickEvent,
        QuickEvent_Done,
        QuickEvent_Progress,
        SearchEvent,
        SearchEvent_Done,
        SearchEvent_Hit,
        StatsEvent,
        StatsEvent_Done,
        StatsEvent_Progress;
export '../src/rust/api/dedupe.dart'
    show DuplicateGroup, ScanPhase, ScanProgress, ScanRequest;
export '../src/rust/api/email.dart'
    show
        EmailAddressInfo,
        EmailAttachmentData,
        EmailAttachmentInfo,
        EmailHeaderInfo,
        EmailMessageInfo;
export '../src/rust/api/fileops.dart'
    show Collision, FailedItem, OpOutcome, OpProgress;
export '../src/rust/api/listing.dart' show DirEntryInfo, SortSpec;
export '../src/rust/api/quick.dart'
    show FolderStats, ImageTarget, ImageTransform, QuickOutcome, QuickProgress;
export '../src/rust/api/search.dart'
    show HitKind, SearchHit, SearchRequest, SearchSummary;
export '../src/rust/api/sharing.dart'
    show
        SmbClientSettings,
        SmbConnectionEvent,
        SmbEntry,
        SmbOpenFile,
        SmbServerEvent,
        SmbServerEvent_Authenticated,
        SmbServerEvent_Connected,
        SmbServerEvent_Disconnected,
        SmbServerEvent_Rejected,
        SmbServerEvent_Started,
        SmbServerEvent_Stopped,
        SmbServerEvent_Transfer,
        SmbServerSettings,
        SmbServerStatus,
        SmbSession,
        SmbShareConfig,
        SmbTransferEvent,
        SmbUserConfig;
export '../src/rust/api/thumbnail.dart' show ThumbnailInfo;
export '../src/rust/api/trash.dart' show TrashOutcome;

/// Single entry point to the Rust core.
///
/// Everything CPU-bound — recursive walks, hashing, copy/move, search, archive
/// decoding, thumbnailing — runs behind this. Wrapping the generated bindings
/// instead of calling them from widgets keeps the `lib/src/rust` surface in one
/// file, so regenerating the bridge can't ripple through the UI.
///
/// Long operations take a caller-chosen `opId` and are stopped with [cancel].
/// A `StreamSink` only flows Rust → Dart, so cancellation has to be a separate
/// call keyed by that id rather than something pushed into the stream.
class NativeCore {
  NativeCore._();
  static final NativeCore instance = NativeCore._();

  static const _uuid = Uuid();
  static bool _initialised = false;

  /// Loads the native library. Safe to call repeatedly; must complete before
  /// anything else here.
  ///
  /// The bridge refuses to initialise twice, and something else may already
  /// have done it — a test harness opening the library from `cargo build`
  /// output is the case that matters — so its own flag is checked before ours.
  static Future<void> ensureInitialized() async {
    if (_initialised || NotilusCore.instance.initialized) {
      _initialised = true;
      return;
    }
    await NotilusCore.init();
    _initialised = true;
  }

  /// A fresh id for a cancellable operation.
  String newOpId() => _uuid.v4();

  /// Cancels the operation running under [opId]. False means it already
  /// finished — expected, not an error worth surfacing.
  Future<bool> cancel(String opId) => rust.cancelOp(opId: opId);

  // ── directory listing ────────────────────────────────────────────────────

  Future<List<rust_listing.DirEntryInfo>> listDir(
    String path, {
    required rust_listing.SortSpec sort,
  }) =>
      rust.listDir(path: path, sort: sort);

  // ── copy / move ──────────────────────────────────────────────────────────

  /// Files and bytes under [paths], for sizing a progress bar before starting.
  Future<({int files, int bytes})> measure(List<String> paths) async {
    // FRB maps a Rust `Vec<u64>` to its own Uint64List, whose elements are
    // BigInt on native targets.
    final r = await rust.measurePaths(paths: paths);
    return (
      files: r.isNotEmpty ? r[0].toInt() : 0,
      bytes: r.length > 1 ? r[1].toInt() : 0,
    );
  }

  /// Copies [sources] into [destDir], streaming progress then a final outcome.
  Stream<rust.OpEvent> copy({
    required List<String> sources,
    required String destDir,
    required String opId,
    rust_fileops.Collision collision = rust_fileops.Collision.rename,
  }) =>
      rust.copyPathsStream(
        sources: sources,
        destDir: destDir,
        collision: collision,
        opId: opId,
      );

  /// Moves [sources] into [destDir]. Uses `rename(2)` where source and
  /// destination share a filesystem, so same-disk moves are instant regardless
  /// of size, and falls back to copy-then-delete across devices.
  Stream<rust.OpEvent> move({
    required List<String> sources,
    required String destDir,
    required String opId,
    rust_fileops.Collision collision = rust_fileops.Collision.rename,
  }) =>
      rust.movePathsStream(
        sources: sources,
        destDir: destDir,
        collision: collision,
        opId: opId,
      );

  Future<String> createFile(String dir, String name) =>
      rust.createFile(dir: dir, name: name);

  Future<String> createDirectory(String dir, String name) =>
      rust.createDir(dir: dir, name: name);

  Future<String> rename(String path, String newName) =>
      rust.renamePath(path: path, newName: newName);

  // ── trash ────────────────────────────────────────────────────────────────

  /// Moves to the platform recycle bin — a real Recycle Bin on Windows and an
  /// XDG trash on Linux, neither of which the Dart implementation had.
  Future<rust_trash.TrashOutcome> moveToTrash(List<String> paths) =>
      rust.moveToTrash(paths: paths);

  /// Bypasses the recycle bin. Callers must confirm with the user first.
  Future<rust_trash.TrashOutcome> deletePermanently(List<String> paths) =>
      rust.deletePermanently(paths: paths);

  // ── search ───────────────────────────────────────────────────────────────

  Stream<rust.SearchEvent> search({
    required rust_search.SearchRequest request,
    required String opId,
  }) =>
      rust.searchFilesStream(req: request, opId: opId);

  // ── duplicates ───────────────────────────────────────────────────────────

  Stream<rust.ScanEvent> scanDuplicates({
    required rust_dedupe.ScanRequest request,
    required String opId,
  }) =>
      rust.scanDuplicatesStream(req: request, opId: opId);

  // ── quick actions ────────────────────────────────────────────────────────

  /// Zips [sources] into [destDir] as [archiveName], streaming progress.
  ///
  /// The name collides non-destructively in Rust, so compressing the same
  /// folder twice yields a second archive rather than overwriting the first.
  Stream<rust.QuickEvent> compress({
    required List<String> sources,
    required String destDir,
    required String archiveName,
    required String opId,
  }) =>
      rust.compressPathsStream(
        sources: sources,
        destDir: destDir,
        archiveName: archiveName,
        opId: opId,
      );

  /// Unpacks an archive into [destDir]. With [intoSubfolder] (the default) the
  /// contents land in a new folder named after the archive, so an archive that
  /// isn't rooted in one directory can't spray files across the current folder.
  Stream<rust.QuickEvent> extractArchive({
    required String path,
    required String destDir,
    required String opId,
    bool intoSubfolder = true,
  }) =>
      rust.extractArchiveStream(
        path: path,
        destDir: destDir,
        intoSubfolder: intoSubfolder,
        opId: opId,
      );

  /// Walks a folder and reports what it holds. A directory's own `stat` size
  /// is the entry's, never its contents', so this is the only way to answer
  /// "how big is this folder?".
  Stream<rust.StatsEvent> folderStats({
    required String path,
    required String opId,
  }) =>
      rust.folderStatsStream(path: path, opId: opId);

  /// Re-encodes an image into [destDir], optionally fitting it inside a
  /// [maxDim] box. Returns the path written; the original is untouched.
  Future<String> convertImage({
    required String src,
    required String destDir,
    required rust_quick.ImageTarget format,
    int? maxDim,
    int quality = 90,
  }) =>
      rust.convertImage(
        src: src,
        destDir: destDir,
        format: format,
        maxDim: maxDim,
        quality: quality,
      );

  /// Rotates or flips an image. With [inPlace] the original is replaced (via a
  /// temp file and a rename, so a failed encode can't destroy it); otherwise a
  /// suffixed sibling is written. Returns the path written.
  Future<String> transformImage({
    required String src,
    required rust_quick.ImageTransform transform,
    bool inPlace = false,
  }) =>
      rust.transformImage(src: src, transform: transform, inPlace: inPlace);

  // ── hashing / archives / thumbnails ──────────────────────────────────────

  Future<String> hashFile(String path) => rust.hashFile(path: path);

  Future<List<rust_archive.ArchiveEntry>> listArchive(String path) =>
      rust.listArchive(path: path);

  Future<Uint8List> extractArchiveEntry(String path, String entryName) =>
      rust.extractArchiveEntry(path: path, entryName: entryName);

  Future<rust_thumbnail.ThumbnailInfo> thumbnail({
    required String src,
    required String dst,
    required int maxDim,
  }) =>
      rust.thumbnailImage(src: src, dst: dst, maxDim: maxDim);

  Future<String> thumbnailCacheKey({
    required String path,
    required int modifiedMs,
    required int size,
    required int dim,
  }) =>
      rust.thumbnailCacheKey(
        path: path,
        modifiedMs: modifiedMs,
        size: BigInt.from(size),
        dim: dim,
      );

  // ── mail files ───────────────────────────────────────────────────────────

  /// Parses a `.eml` or `.msg` into headers, bodies and an attachment list.
  ///
  /// Attachment *contents* are deliberately left behind: a message with a
  /// 40 MB deck in it would otherwise cost 40 MB of Dart heap just to show its
  /// subject line.
  Future<rust_email.EmailMessageInfo> readEmail(String path) =>
      rust.readEmailMessage(path: path);

  /// The bytes of one attachment, addressed by its index in the parsed
  /// message.
  Future<rust_email.EmailAttachmentData> readEmailAttachment(
    String path,
    int index,
  ) =>
      rust.readEmailAttachmentBytes(path: path, index: index);

  /// Writes one attachment into [destDir] and returns the path it was given.
  /// Never overwrites: a name that is taken gets numbered.
  Future<String> saveEmailAttachment({
    required String path,
    required int index,
    required String destDir,
  }) =>
      rust.saveEmailAttachmentTo(path: path, index: index, destDir: destDir);

  // ── file sharing: the server ─────────────────────────────────────────────

  /// Starts the SMB server and streams what it does.
  ///
  /// The stream stays open until [stopSharing]; listening to it is what keeps
  /// the server's event sink alive, so the caller must not drop it early.
  Stream<rust_sharing.SmbServerEvent> startSharing(
    rust_sharing.SmbServerSettings settings,
  ) =>
      rust.smbServerStart(settings: settings);

  Future<bool> stopSharing() => rust.smbServerStop();

  Future<rust_sharing.SmbServerStatus> sharingStatus() =>
      rust.smbServerStatus();

  // ── file sharing: the client ─────────────────────────────────────────────

  Future<rust_sharing.SmbSession> smbConnect(
    rust_sharing.SmbClientSettings settings,
  ) =>
      rust.smbClientConnect(settings: settings);

  /// Checks credentials without keeping a session, returning the dialect that
  /// was negotiated.
  Future<String> smbProbe(rust_sharing.SmbClientSettings settings) =>
      rust.smbClientProbe(settings: settings);

  Future<bool> smbDisconnect(String sessionId) =>
      rust.smbClientDisconnect(sessionId: sessionId);

  Future<List<rust_sharing.SmbEntry>> smbList(String sessionId, String path) =>
      rust.smbClientList(sessionId: sessionId, path: path);

  Future<rust_sharing.SmbEntry?> smbStat(String sessionId, String path) =>
      rust.smbClientStat(sessionId: sessionId, path: path);

  Future<rust_sharing.SmbOpenFile> smbOpen({
    required String sessionId,
    required String path,
    bool write = false,
    bool truncate = false,
  }) =>
      rust.smbClientOpen(
        sessionId: sessionId,
        path: path,
        write: write,
        truncate: truncate,
      );

  /// Reads at most [length] bytes. An empty result means end of file.
  Future<Uint8List> smbRead({
    required String sessionId,
    required BigInt handle,
    required int offset,
    required int length,
  }) =>
      rust.smbClientRead(
        sessionId: sessionId,
        handle: handle,
        offset: BigInt.from(offset),
        length: length,
      );

  /// Writes at [offset], returning how many bytes the server took — which may
  /// be fewer than were offered, so callers loop.
  Future<int> smbWrite({
    required String sessionId,
    required BigInt handle,
    required int offset,
    required Uint8List data,
  }) =>
      rust.smbClientWrite(
        sessionId: sessionId,
        handle: handle,
        offset: BigInt.from(offset),
        data: data,
      );

  Future<void> smbClose(String sessionId, BigInt handle) =>
      rust.smbClientClose(sessionId: sessionId, handle: handle);

  Future<void> smbCreateDirectory(String sessionId, String path) =>
      rust.smbClientCreateDirectory(sessionId: sessionId, path: path);

  Future<void> smbDelete(String sessionId, String path, bool isDir) =>
      rust.smbClientDelete(sessionId: sessionId, path: path, isDir: isDir);

  Future<void> smbRename({
    required String sessionId,
    required String from,
    required String to,
    bool replace = false,
  }) =>
      rust.smbClientRename(
        sessionId: sessionId,
        from: from,
        to: to,
        replace: replace,
      );

  /// Copies a file inside one share, server-side where the server supports it.
  Future<BigInt> smbCopy(String sessionId, String from, String to) =>
      rust.smbClientCopy(sessionId: sessionId, from: from, to: to);
}

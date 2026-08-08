import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../models/file_entry.dart';

/// Generates small raster previews for files and caches them on disk.
///
/// In-memory map keys are `<absPath>|<mtimeMs>|<size>|<dim>` so a file edit
/// invalidates the cache automatically. On-disk filenames are stable hashes
/// of that same key so cached PNGs survive app restarts.
///
/// Three families of preview live here, in increasing order of how much they
/// cost:
///  * text snippets — a read of the first couple of KB, no image at all;
///  * embedded previews — the cover ODF/OOXML/EPUB files already carry inside
///    themselves, lifted out of the zip;
///  * rendered previews — PDF pages and video frames, which mean a decoder or
///    an external process, and so run behind a concurrency gate.
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  Directory? _cacheDir;
  final Map<String, Future<File?>> _inFlight = {};

  /// Keys whose generation already failed. Without this, a video the machine
  /// has no decoder for would re-spawn ffmpeg every time its tile scrolls back
  /// into view.
  final Set<String> _failed = {};

  /// External renderers are process spawns; a grid scrolled quickly would ask
  /// for dozens at once. This many at a time keeps the machine responsive and
  /// still fills a screen of tiles promptly.
  ///
  /// Measured on a 12-core machine over 24 1080p clips: 3.1s three at a time,
  /// 2.4s six, 2.1s eight, 2.0s twelve. The curve flattens early because the
  /// cost is process startup and I/O rather than decode, so this stops well
  /// short of the core count — the remaining few percent are not worth handing
  /// the whole machine to a background nicety.
  static final int _maxConcurrentRenders = _pickConcurrency();

  static int _pickConcurrency() {
    if (kIsWeb) return 3;
    return (Platform.numberOfProcessors - 2).clamp(3, 8);
  }

  int _rendering = 0;
  final Queue<Completer<void>> _renderQueue = Queue();

  /// Directories searched for renderers beyond whatever `PATH` says.
  ///
  /// A GUI process on macOS inherits launchd's environment, whose PATH is only
  /// `/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew and MacPorts install outside all
  /// four, so a Notilus started from the Dock cannot see the ffmpeg that every
  /// terminal on the same machine finds instantly: video thumbnails quietly
  /// fall through to QuickLook, which measured ~2.5x slower per clip, and on
  /// Linux they fall through to no thumbnail at all.
  static const List<String> _extraToolDirs = [
    '/opt/homebrew/bin', // Homebrew on Apple silicon
    '/usr/local/bin', // Homebrew on Intel, and the usual make-install target
    '/opt/local/bin', // MacPorts
    '/usr/bin', // qlmanage, and distro packages
    '/bin',
    '/snap/bin', // Ubuntu snaps
  ];

  /// Absolute paths of renderers, with null meaning "not on this machine".
  final Map<String, String?> _toolPaths = {};

  /// How long an external renderer gets before it is killed. A malformed file
  /// can make ffmpeg spin indefinitely, and a stuck process would otherwise
  /// hold a slot in the gate forever.
  static const Duration _renderTimeout = Duration(seconds: 20);

  static const Set<String> _videoExts = {
    '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v', '.mpg', '.mpeg',
    '.wmv', '.3gp',
  };

  /// Container formats that are really zips with a preview inside.
  static const Set<String> _zipDocExts = {
    '.odt', '.ods', '.odp', '.odg',
    '.docx', '.xlsx', '.pptx',
    '.epub',
  };

  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.mdown', '.log', '.csv', '.tsv',
    '.json', '.yaml', '.yml', '.xml', '.rtf',
  };

  /// Whether [entry] has any preview better than an icon. Callers use this to
  /// decide between an async thumbnail widget and a plain glyph.
  bool canPreview(FileEntry entry) =>
      hasRenderedPreview(entry) ||
      hasEmbeddedPreview(entry) ||
      hasTextPreview(entry);

  bool hasRenderedPreview(FileEntry entry) =>
      entry.extension == '.pdf' || isVideo(entry);

  bool hasEmbeddedPreview(FileEntry entry) =>
      _zipDocExts.contains(entry.extension);

  bool hasTextPreview(FileEntry entry) => _textExts.contains(entry.extension);

  bool isVideo(FileEntry entry) => _videoExts.contains(entry.extension);

  Future<Directory> _ensureDir() async {
    // Re-checked rather than memoised outright: if the cache folder is removed
    // while the app runs — a cleanup tool, a user emptying app support — a
    // remembered handle would make every later write fail silently.
    final cached = _cacheDir;
    if (cached != null && await cached.exists()) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'thumbnails'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  String _key(FileEntry f, int dim, String tag) {
    return '${f.path}|${f.modified.millisecondsSinceEpoch}|${f.size}|$dim|$tag';
  }

  String _hash(String key) {
    // Simple FNV-1a 64-bit — enough for cache filenames, no security needs.
    var h = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final code in key.codeUnits) {
      h ^= code;
      h = (h * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  /// The one path every disk-cached preview goes through: dedupes concurrent
  /// requests, reuses an existing file, and remembers failures.
  ///
  /// [generate] writes the PNG to the file it is handed and reports whether it
  /// produced anything; an empty or missing result counts as a failure.
  Future<File?> _cached(
    String key,
    Future<bool> Function(File out) generate,
  ) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    if (_failed.contains(key)) return Future.value(null);

    final fut = _generateCached(key, generate);
    _inFlight[key] = fut;
    fut.whenComplete(() => _inFlight.remove(key));
    return fut;
  }

  Future<File?> _generateCached(
    String key,
    Future<bool> Function(File out) generate,
  ) async {
    try {
      final dir = await _ensureDir();
      final out = File(p.join(dir.path, '${_hash(key)}.png'));
      if (await _isUsable(out)) return out;

      final produced = await generate(out);
      if (!produced || !await _isUsable(out)) {
        _failed.add(key);
        return null;
      }
      return out;
    } catch (_) {
      _failed.add(key);
      return null;
    }
  }

  Future<bool> _isUsable(File f) async {
    try {
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Runs [body] with at most [_maxConcurrentRenders] others in flight.
  Future<T> _gated<T>(Future<T> Function() body) async {
    if (_rendering >= _maxConcurrentRenders) {
      final waiter = Completer<void>();
      _renderQueue.add(waiter);
      await waiter.future;
    }
    _rendering++;
    try {
      return await body();
    } finally {
      _rendering--;
      if (_renderQueue.isNotEmpty) _renderQueue.removeFirst().complete();
    }
  }

  // ── PDF ──────────────────────────────────────────────────────────────────

  Future<File?> pdfThumbnail(FileEntry f, {int dim = 240}) {
    return _cached(
      _key(f, dim, 'pdf'),
      (out) => _gated(() => _renderPdf(f, dim, out)),
    );
  }

  Future<bool> _renderPdf(FileEntry f, int dim, File out) async {
    if (!kIsWeb && Platform.isLinux) {
      // Poppler renders without pulling a PDF engine into this process, and is
      // present on essentially every desktop Linux install. pdfx has no Linux
      // implementation at all — calling it there throws rather than returning
      // a miss — so poppler is the whole story on that platform.
      return _pdfViaPoppler(f, dim, out);
    }
    return _pdfViaPdfx(f, dim, out);
  }

  Future<bool> _pdfViaPdfx(FileEntry f, int dim, File out) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(f.path);
      if (doc.pagesCount == 0) return false;
      final page = await doc.getPage(1);
      try {
        final ratio = page.height == 0 ? 1.0 : page.width / page.height;
        final w = dim.toDouble();
        final h = (dim / (ratio == 0 ? 1.0 : ratio)).clamp(40, dim * 2.0);
        final img = await page.render(
          width: w,
          height: h.toDouble(),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        final bytes = img?.bytes;
        if (bytes == null) return false;
        await out.writeAsBytes(bytes, flush: true);
        return true;
      } finally {
        await page.close();
      }
    } catch (_) {
      return false;
    } finally {
      await doc?.close();
    }
  }

  Future<bool> _pdfViaPoppler(FileEntry f, int dim, File out) async {
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_thumb_');
      final prefix = p.join(tmp.path, 'p');
      // Compute DPI from desired pixel width assuming ~8.5in page width.
      final dpi = (dim / 8.5).clamp(40, 200).round();
      final ok = await _runProcess('pdftoppm', [
        '-png',
        '-r', '$dpi',
        '-f', '1',
        '-l', '1',
        '-singlefile',
        f.path,
        prefix,
      ]);
      if (!ok) return false;
      final png = File('$prefix.png');
      if (!await png.exists()) return false;
      await png.copy(out.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (tmp != null) {
        unawaited(tmp.delete(recursive: true).catchError((_) => tmp!));
      }
    }
  }

  // ── video ────────────────────────────────────────────────────────────────

  /// A single frame from a little way into the video, cached as a PNG.
  ///
  /// There is no in-process video decoder — `video_player` renders to a
  /// platform surface it won't hand back as pixels — so this shells out.
  /// Where no renderer is installed the caller falls back to a glyph.
  Future<File?> videoThumbnail(FileEntry f, {int dim = 320}) {
    return _cached(
      _key(f, dim, 'video'),
      (out) => _gated(() => _renderVideoFrame(f, dim, out)),
    );
  }

  Future<bool> _renderVideoFrame(FileEntry f, int dim, File out) async {
    // Purpose-built and fastest where it exists: seeks smartly and picks a
    // frame that isn't a black lead-in.
    if (await _runProcess('ffmpegthumbnailer', [
      '-i', f.path,
      '-o', out.path,
      '-s', '$dim',
      '-q', '8',
    ])) {
      if (await _isUsable(out)) return true;
    }

    // Seek before -i so ffmpeg jumps rather than decoding up to the mark. A
    // clip shorter than the seek yields nothing, hence the retry at zero.
    for (final seek in ['00:00:01', '00:00:00']) {
      final ok = await _runProcess('ffmpeg', [
        '-y',
        '-loglevel', 'error',
        '-ss', seek,
        '-i', f.path,
        '-frames:v', '1',
        // Downscale only if the source is larger, and keep the aspect ratio on
        // an even height (some encoders reject odd dimensions).
        '-vf', "scale='min($dim,iw)':-2",
        out.path,
      ]);
      if (ok && await _isUsable(out)) return true;
    }

    if (!kIsWeb && Platform.isMacOS) {
      return _viaQuickLook(f, dim, out);
    }
    return false;
  }

  /// macOS ships a thumbnailer for everything Finder can preview — video,
  /// Keynote, Office — so it is the last resort on that platform.
  Future<bool> _viaQuickLook(FileEntry f, int dim, File out) async {
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_ql_');
      final ok = await _runProcess('qlmanage', [
        '-t',
        '-s', '$dim',
        '-o', tmp.path,
        f.path,
      ]);
      if (!ok) return false;
      // qlmanage names its output "<original name>.png".
      final produced = tmp
          .listSync()
          .whereType<File>()
          .where((e) => e.path.toLowerCase().endsWith('.png'))
          .toList();
      if (produced.isEmpty) return false;
      await produced.first.copy(out.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (tmp != null) {
        unawaited(tmp.delete(recursive: true).catchError((_) => tmp!));
      }
    }
  }

  /// Where [exe] actually lives, or null when this machine hasn't got it.
  ///
  /// Resolved by looking at the filesystem rather than by spawning and seeing
  /// what happens: a failed spawn measured ~15ms, and the video path tries two
  /// renderers before QuickLook, so a folder of clips on a machine without
  /// ffmpeg used to pay that twice per file for nothing — while holding a slot
  /// in the render gate. Memoised for the life of the process.
  String? _resolveTool(String exe) {
    if (_toolPaths.containsKey(exe)) return _toolPaths[exe];
    final resolved = _lookupTool(exe);
    _toolPaths[exe] = resolved;
    return resolved;
  }

  String? _lookupTool(String exe) {
    if (kIsWeb) return null;
    // Windows resolution has its own rules — PATHEXT, the current directory —
    // so let the OS do it there. The ProcessException memo below still saves
    // the repeat spawns.
    if (Platform.isWindows) return exe;
    final fromEnv = Platform.environment['PATH']?.split(':') ?? const [];
    for (final dir in [...fromEnv, ..._extraToolDirs]) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, exe);
      try {
        final stat = FileStat.statSync(candidate);
        // The execute bit matters: a same-named data file earlier on PATH
        // would otherwise "resolve" and every spawn would fail.
        if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
          return candidate;
        }
      } catch (_) {
        // Unreadable directory on PATH — keep looking.
      }
    }
    return null;
  }

  /// Starts [exe], enforcing [_renderTimeout]. A missing executable is a
  /// normal outcome here, not an error worth surfacing.
  Future<bool> _runProcess(String exe, List<String> args) async {
    final resolved = _resolveTool(exe);
    if (resolved == null) return false;
    Process? proc;
    try {
      proc = await Process.start(resolved, args);
      // Drain both pipes: a renderer that fills its stderr buffer while nobody
      // reads it blocks forever.
      unawaited(proc.stdout.drain<void>().catchError((_) {}));
      unawaited(proc.stderr.drain<void>().catchError((_) {}));
      final code = await proc.exitCode.timeout(
        _renderTimeout,
        onTimeout: () {
          proc?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      return code == 0;
    } on ProcessException {
      // Not installed after all — remember it, so the next file in the folder
      // doesn't pay for another failed spawn.
      _toolPaths[exe] = null;
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── embedded previews ────────────────────────────────────────────────────

  /// Lifts the preview image an office document or ebook already carries.
  ///
  /// ODF files always store `Thumbnails/thumbnail.png`; OOXML files store
  /// `docProps/thumbnail.*` only when the author saved one; EPUBs carry a
  /// cover image. Nothing is rendered, so this works on every platform with no
  /// external tools — but it can only ever return what the file itself has.
  Future<File?> embeddedThumbnail(FileEntry f, {int dim = 320}) {
    return _cached(
      _key(f, dim, 'embedded'),
      (out) async {
        // Zip central-directory reads are synchronous in the archive package,
        // so they go to another isolate rather than stalling a scroll. Only
        // the path is captured, so the closure stays trivially sendable.
        final path = f.path;
        final bytes = await Isolate.run(() => _extractEmbeddedPreview(path));
        if (bytes == null || bytes.isEmpty) return false;
        await out.writeAsBytes(bytes, flush: true);
        return true;
      },
    );
  }

  // ── text ─────────────────────────────────────────────────────────────────

  /// Reads up to [maxBytes] of a text file synchronously-ish, for snippet
  /// thumbnails. Returns `null` if the file looks binary.
  Future<String?> textSnippet(FileEntry f, {int maxBytes = 2048}) async {
    try {
      final file = File(f.path);
      final raf = await file.open();
      try {
        final len = await file.length();
        final readLen = len < maxBytes ? len : maxBytes;
        final bytes = await raf.read(readLen);
        // Crude binary sniff: any 0x00 byte → treat as binary.
        for (final b in bytes) {
          if (b == 0) return null;
        }
        return String.fromCharCodes(bytes);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> readBytes(FileEntry f, {int? maxBytes}) async {
    try {
      final file = File(f.path);
      if (maxBytes == null) return await file.readAsBytes();
      final raf = await file.open();
      try {
        final len = await file.length();
        final readLen = len < maxBytes ? len : maxBytes;
        return await raf.read(readLen);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Test hook: forgets cached failures so a fixture can be retried.
  @visibleForTesting
  void debugClearFailures() {
    _failed.clear();
    _toolPaths.clear();
  }

  /// Test hook: where an external renderer was found, or null for absent.
  @visibleForTesting
  String? debugResolveTool(String exe) => _resolveTool(exe);

  /// Test hook: the non-PATH directories searched for renderers.
  @visibleForTesting
  static List<String> get debugExtraToolDirs => _extraToolDirs;

  /// Test hook: how many renderers may run at once on this machine.
  @visibleForTesting
  static int get debugMaxConcurrentRenders => _maxConcurrentRenders;
}

/// Runs in a background isolate — top-level and free of Flutter types.
///
/// Returns the raw bytes of the best preview image inside [path], or null when
/// the container has none.
Uint8List? _extractEmbeddedPreview(String path) {
  InputFileStream? input;
  try {
    input = InputFileStream(path);
    final archive = ZipDecoder().decodeBuffer(input);

    // Exact locations first: ODF and OOXML both put the preview at a fixed
    // path, so a name match beats scanning for candidates.
    const known = [
      'thumbnails/thumbnail.png',
      'docprops/thumbnail.jpeg',
      'docprops/thumbnail.jpg',
      'docprops/thumbnail.png',
    ];
    for (final want in known) {
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (file.name.toLowerCase() == want) {
          final content = file.content;
          if (content is List<int> && content.isNotEmpty) {
            return Uint8List.fromList(content);
          }
        }
      }
    }

    // EPUB: the cover is named in the OPF, but "the biggest image with 'cover'
    // in its path" finds it in practice without parsing XML.
    ArchiveFile? best;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.toLowerCase();
      final isImage = name.endsWith('.jpg') ||
          name.endsWith('.jpeg') ||
          name.endsWith('.png');
      if (!isImage || !name.contains('cover')) continue;
      if (best == null || file.size > best.size) best = file;
    }
    final content = best?.content;
    if (content is List<int> && content.isNotEmpty) {
      return Uint8List.fromList(content);
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      input?.closeSync();
    } catch (_) {}
  }
}

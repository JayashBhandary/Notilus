import 'dart:async';
import 'dart:io';

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
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  Directory? _cacheDir;
  final Map<String, Future<File?>> _inFlight = {};

  Future<Directory> _ensureDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'thumbnails'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  String _key(FileEntry f, int dim) {
    return '${f.path}|${f.modified.millisecondsSinceEpoch}|${f.size}|$dim';
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

  Future<File?> pdfThumbnail(FileEntry f, {int dim = 240}) {
    final key = _key(f, dim);
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final fut = _generatePdfThumbnail(f, dim, key);
    _inFlight[key] = fut;
    fut.whenComplete(() => _inFlight.remove(key));
    return fut;
  }

  Future<File?> _generatePdfThumbnail(FileEntry f, int dim, String key) async {
    try {
      final dir = await _ensureDir();
      final out = File(p.join(dir.path, '${_hash(key)}.png'));
      if (await out.exists()) return out;

      if (!kIsWeb && Platform.isLinux) {
        return await _pdfThumbnailViaPoppler(f, dim, out);
      }
      return await _pdfThumbnailViaPdfx(f, dim, out);
    } catch (_) {
      return null;
    }
  }

  Future<File?> _pdfThumbnailViaPdfx(FileEntry f, int dim, File out) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(f.path);
      if (doc.pagesCount == 0) return null;
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
        if (bytes == null) return null;
        await out.writeAsBytes(bytes, flush: true);
        return out;
      } finally {
        await page.close();
      }
    } catch (_) {
      return null;
    } finally {
      await doc?.close();
    }
  }

  Future<File?> _pdfThumbnailViaPoppler(FileEntry f, int dim, File out) async {
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('notilus_thumb_');
      final prefix = p.join(tmp.path, 'p');
      // Compute DPI from desired pixel width assuming ~8.5in page width.
      final dpi = (dim / 8.5).clamp(40, 200).round();
      final r = await Process.run('pdftoppm', [
        '-png',
        '-r', '$dpi',
        '-f', '1',
        '-l', '1',
        '-singlefile',
        f.path,
        prefix,
      ]);
      if (r.exitCode != 0) return null;
      final png = File('$prefix.png');
      if (!await png.exists()) return null;
      await png.copy(out.path);
      return out;
    } on ProcessException {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (tmp != null) {
        // Fire-and-forget.
        unawaited(tmp.delete(recursive: true).catchError((_) => tmp!));
      }
    }
  }

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
}

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Outcome of a compress run. [added] and [skipped] are file counts; anything
/// that vanished between selection and zipping lands in [skipped] rather than
/// failing the whole archive.
class CompressResult {
  const CompressResult({
    required this.zipPath,
    required this.added,
    required this.skipped,
  });

  /// Empty when nothing was archivable, in which case no file was written.
  final String zipPath;
  final int added;
  final int skipped;

  bool get wroteArchive => zipPath.isNotEmpty && added > 0;
}

/// Zips a set of loose files into a single archive.
///
/// The Rust core only *reads* archives (`list_archive` / `extract_archive_entry`),
/// so compression goes through the Dart `archive` package instead of growing a
/// new bridge call. The encode is synchronous and CPU-bound, so it runs in a
/// background isolate — on the main isolate a few hundred photos would freeze
/// the window for seconds.
///
/// The trade-off of [Isolate.run] is that there is no progress channel and no
/// cancellation; callers show an indeterminate state and wait.
class MediaArchiveService {
  const MediaArchiveService();

  static const MediaArchiveService instance = MediaArchiveService();

  /// Archives [paths] into `<destDir>/<baseName>-YYYY-MM-DD.zip`.
  ///
  /// Directories and missing files are skipped. Entries are stored flat, by
  /// basename, with `(2)`-style suffixes where two source folders contribute
  /// the same name. An existing archive is never overwritten — the filename
  /// gains a `-2`, `-3`… suffix instead.
  Future<CompressResult> compressToZip({
    required List<String> paths,
    required String destDir,
    required String baseName,
    required DateTime stamp,
  }) async {
    final used = <String>{};
    // [absolutePath, nameInsideZip] pairs — a plain List so the job stays
    // trivially sendable to another isolate.
    final files = <List<String>>[];
    var skipped = 0;

    for (final path in paths) {
      bool isFile;
      try {
        isFile = FileSystemEntity.isFileSync(path);
      } catch (_) {
        isFile = false;
      }
      if (!isFile) {
        skipped++;
        continue;
      }
      files.add([path, _uniqueEntryName(p.basename(path), used)]);
    }

    if (files.isEmpty) {
      return CompressResult(zipPath: '', added: 0, skipped: skipped);
    }

    final dir = Directory(destDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final zipPath = _freeArchivePath(destDir, baseName, stamp);
    await Isolate.run(() => _zipFiles(zipPath, files));

    return CompressResult(
      zipPath: zipPath,
      added: files.length,
      skipped: skipped,
    );
  }

  String _uniqueEntryName(String name, Set<String> used) {
    if (used.add(name)) return name;
    final ext = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    for (var i = 2;; i++) {
      final candidate = '$stem ($i)$ext';
      if (used.add(candidate)) return candidate;
    }
  }

  String _freeArchivePath(String destDir, String baseName, DateTime stamp) {
    final date = '${stamp.year.toString().padLeft(4, '0')}-'
        '${stamp.month.toString().padLeft(2, '0')}-'
        '${stamp.day.toString().padLeft(2, '0')}';
    final first = p.join(destDir, '$baseName-$date.zip');
    if (!File(first).existsSync()) return first;
    for (var i = 2;; i++) {
      final candidate = p.join(destDir, '$baseName-$date-$i.zip');
      if (!File(candidate).existsSync()) return candidate;
    }
  }
}

/// Runs in a background isolate — keep it top-level and free of Flutter types.
Future<void> _zipFiles(String zipPath, List<List<String>> files) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  try {
    for (final entry in files) {
      await encoder.addFile(File(entry[0]), entry[1]);
    }
  } finally {
    await encoder.close();
  }
}

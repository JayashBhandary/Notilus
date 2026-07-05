import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../models/file_entry.dart';

/// Cross-platform "Finder-action" helpers. Returns success/failure so the
/// caller can show an error dialog. All methods avoid throwing on
/// missing-permission / path-doesn't-exist conditions.
class FileActionsService {
  bool get _isMacOS => !kIsWeb && Platform.isMacOS;
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// Opens the entry in the system's default associated app.
  /// macOS: `open <path>`. iOS: presents the system share sheet.
  Future<bool> openInDefaultApp(FileEntry entry) async {
    if (_isMacOS) {
      final r = await Process.run('open', [entry.path]);
      return r.exitCode == 0;
    }
    if (_isIOS) {
      // Share sheet is the iOS equivalent of "Open With".
      final result = await Share.shareXFiles([XFile(entry.path)]);
      return result.status != ShareResultStatus.unavailable;
    }
    return false;
  }

  /// macOS: shows the native "Choose Application" dialog (StandardAdditions
  /// `choose application`) and opens the entry in the picked app.
  /// iOS: presents the share sheet so the user can pick a receiver.
  /// Returns false if the user cancelled or no compatible flow exists.
  Future<bool> openWithChooser(FileEntry entry) async {
    if (_isMacOS) {
      final escaped =
          entry.path.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script =
          'tell application "Finder" to open POSIX file "$escaped" '
          'using (choose application)';
      final r = await Process.run('osascript', ['-e', script]);
      return r.exitCode == 0;
    }
    return openInDefaultApp(entry);
  }

  /// Copies the entry's absolute path to the system clipboard.
  Future<void> copyPath(FileEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path));
  }

  /// macOS: reveals the entry in Finder (`open -R`). Returns false on iOS.
  Future<bool> revealInOs(FileEntry entry) async {
    if (_isMacOS) {
      final r = await Process.run('open', ['-R', entry.path]);
      return r.exitCode == 0;
    }
    return false;
  }

  /// Renames an entry. Returns the new path on success, null on failure.
  Future<String?> rename(FileEntry entry, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return null;
    final newPath = p.join(p.dirname(entry.path), trimmed);
    if (await FileSystemEntity.type(newPath) !=
        FileSystemEntityType.notFound) {
      return null; // would collide
    }
    try {
      final type = await FileSystemEntity.type(entry.path);
      if (type == FileSystemEntityType.directory) {
        final renamed = await Directory(entry.path).rename(newPath);
        return renamed.path;
      } else {
        final renamed = await File(entry.path).rename(newPath);
        return renamed.path;
      }
    } on FileSystemException {
      return null;
    }
  }

  /// Makes a sibling copy with " copy" / " copy 2" / … suffixed.
  /// Returns the new path on success.
  Future<String?> duplicate(FileEntry entry) async {
    final dir = p.dirname(entry.path);
    final base = p.basenameWithoutExtension(entry.name);
    final ext = p.extension(entry.name); // includes leading dot
    String candidate = entry.isDirectory
        ? '$base copy'
        : '$base copy$ext';
    var idx = 2;
    while (await FileSystemEntity.type(p.join(dir, candidate)) !=
        FileSystemEntityType.notFound) {
      candidate = entry.isDirectory
          ? '$base copy $idx'
          : '$base copy $idx$ext';
      idx++;
    }
    final dest = p.join(dir, candidate);
    try {
      if (entry.isDirectory) {
        await _copyDirectory(Directory(entry.path), Directory(dest));
      } else {
        await File(entry.path).copy(dest);
      }
      return dest;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _copyDirectory(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(e.path);
      final destPath = p.join(dst.path, name);
      if (e is Directory) {
        await _copyDirectory(e, Directory(destPath));
      } else if (e is File) {
        await e.copy(destPath);
      }
    }
  }

  /// macOS: moves to Trash via Finder AppleScript.
  /// iOS / other: hard-deletes (no system Trash inside the app sandbox).
  Future<bool> trash(FileEntry entry) async {
    if (_isMacOS) {
      final escaped = entry.path.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final script =
          'tell application "Finder" to delete (POSIX file "$escaped" as alias)';
      final r = await Process.run('osascript', ['-e', script]);
      return r.exitCode == 0;
    }
    try {
      if (entry.isDirectory) {
        await Directory(entry.path).delete(recursive: true);
      } else {
        await File(entry.path).delete();
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Moves every entry in [entries] to the Trash in as few operations as
  /// possible, so a bulk cleanup doesn't replay the Trash sound once per file.
  /// Returns the set of paths that could NOT be trashed (empty on full
  /// success).
  ///
  /// macOS: a single Finder `delete` handles the whole list — one sound for
  /// the batch. The list is chunked so a huge selection can't blow past the
  /// command-line length limit; each chunk is still one sound. Other platforms
  /// have no batch Trash API here, so they reuse the per-file [trash] path
  /// (which involves no system sound anyway).
  Future<Set<String>> trashAll(List<FileEntry> entries) async {
    if (entries.isEmpty) return <String>{};

    if (_isMacOS) {
      // A path that no longer exists makes `... as alias` throw and aborts the
      // whole batch, so drop anything already gone (treat it as trashed).
      final present = <FileEntry>[];
      for (final e in entries) {
        if (await FileSystemEntity.type(e.path) !=
            FileSystemEntityType.notFound) {
          present.add(e);
        }
      }
      if (present.isEmpty) return <String>{};

      final failed = <String>{};
      const chunkSize = 100;
      for (var start = 0; start < present.length; start += chunkSize) {
        final end = (start + chunkSize < present.length)
            ? start + chunkSize
            : present.length;
        final chunk = present.sublist(start, end);
        final aliases = chunk
            .map((e) =>
                'POSIX file "${e.path.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}" as alias')
            .join(', ');
        final script = 'tell application "Finder" to delete {$aliases}';
        final r = await Process.run('osascript', ['-e', script]);
        if (r.exitCode != 0) {
          // Batch failed (e.g. one item wasn't deletable). Retry this chunk
          // per file so we can report exactly which paths failed and still
          // trash the rest.
          for (final e in chunk) {
            if (!await trash(e)) failed.add(e.path);
          }
        }
      }
      return failed;
    }

    // No batch Trash on other platforms — fall back to per-file delete.
    final failed = <String>{};
    for (final e in entries) {
      if (!await trash(e)) failed.add(e.path);
    }
    return failed;
  }
}

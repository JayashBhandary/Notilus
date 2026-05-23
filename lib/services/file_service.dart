import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/file_entry.dart';

class DirectoryListing {
  DirectoryListing({required this.entries, this.error});
  final List<FileEntry> entries;
  final String? error;
}

class DriveEntry {
  DriveEntry({required this.name, required this.path, this.isRoot = false});
  final String name;
  final String path;
  final bool isRoot;
}

class FileService {
  static const int _textReadCap = 200 * 1024; // 200KB

  Future<DirectoryListing> listDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      return DirectoryListing(
        entries: const [],
        error: 'Folder does not exist: $path',
      );
    }
    final List<FileEntry> entries = [];
    String? error;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue; // hide dotfiles
        final entry = await FileEntry.from(entity);
        if (entry != null) entries.add(entry);
      }
    } on PathAccessException catch (e) {
      error = 'Permission denied: ${e.message}';
    } on FileSystemException catch (e) {
      error = e.message;
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirectoryListing(entries: entries, error: error);
  }

  Future<String?> homePath() async {
    final env = Platform.environment;
    if (Platform.isWindows) return env['USERPROFILE'];
    return env['HOME'];
  }

  Future<Map<String, String?>> shortcuts() async {
    final home = await homePath();
    String? docs, downloads, desktop;
    if (home != null) {
      desktop = p.join(home, 'Desktop');
      docs = p.join(home, 'Documents');
      downloads = p.join(home, 'Downloads');
    } else {
      try {
        docs = (await getApplicationDocumentsDirectory()).path;
      } catch (_) {}
      try {
        downloads = (await getDownloadsDirectory())?.path;
      } catch (_) {}
    }
    return {
      'Home': home,
      'Desktop': desktop,
      'Documents': docs,
      'Downloads': downloads,
    };
  }

  /// Enumerates mounted volumes / drives the user can browse.
  ///
  /// macOS: lists `/Volumes/*` (covers internal "Macintosh HD" + external).
  /// Linux: lists `/media/<user>/*` and `/mnt/*` and adds `/`.
  /// Windows: probes drive letters A:..Z: and returns the ones that exist.
  Future<List<DriveEntry>> drives() async {
    if (Platform.isMacOS) {
      return _listDir('/Volumes', isMac: true);
    }
    if (Platform.isLinux) {
      final user = Platform.environment['USER'];
      final candidates = <String>[
        if (user != null) '/media/$user',
        '/media',
        '/mnt',
        '/run/media/${user ?? ''}',
      ];
      final result = <DriveEntry>[
        DriveEntry(name: 'Root', path: '/', isRoot: true),
      ];
      for (final c in candidates) {
        result.addAll(await _listDir(c, isMac: false));
      }
      return result;
    }
    if (Platform.isWindows) {
      final result = <DriveEntry>[];
      for (final code in 'CDEFGHIJKLMNOPQRSTUVWXYZAB'.codeUnits) {
        final letter = String.fromCharCode(code);
        final path = '$letter:\\';
        if (await Directory(path).exists()) {
          result.add(DriveEntry(
            name: '$letter:',
            path: path,
            isRoot: letter == 'C',
          ));
        }
      }
      return result;
    }
    return const [];
  }

  Future<List<DriveEntry>> _listDir(String parent, {required bool isMac}) async {
    final dir = Directory(parent);
    if (!await dir.exists()) return const [];
    final List<DriveEntry> out = [];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        out.add(DriveEntry(
          name: name,
          path: entity.path,
          // On macOS, `/Volumes/Macintosh HD` is the internal disk.
          isRoot: isMac && name == 'Macintosh HD',
        ));
      }
    } on FileSystemException {
      return out;
    }
    out.sort((a, b) {
      if (a.isRoot != b.isRoot) return a.isRoot ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// Creates a new directory inside [parent], returning the created path.
  /// Picks a unique name if [name] already exists (Finder-style "untitled folder 2").
  Future<String?> createDirectory(String parent, String name) async {
    var candidate = name;
    var idx = 2;
    String fullPath() => p.join(parent, candidate);
    while (await Directory(fullPath()).exists() ||
        await File(fullPath()).exists()) {
      candidate = '$name $idx';
      idx++;
    }
    try {
      final dir = await Directory(fullPath()).create();
      return dir.path;
    } on FileSystemException {
      return null;
    }
  }

  bool _looksTextual(String path) {
    const textExts = {
      '.txt', '.md', '.json', '.yaml', '.yml', '.xml', '.csv', '.html',
      '.css', '.js', '.ts', '.tsx', '.jsx', '.dart', '.py', '.rb', '.go',
      '.rs', '.c', '.cpp', '.h', '.hpp', '.java', '.kt', '.swift', '.sh',
      '.toml', '.ini', '.conf', '.log',
    };
    return textExts.contains(p.extension(path).toLowerCase());
  }

  Future<String> readTextCapped(String path) async {
    if (!_looksTextual(path)) {
      return '[binary or unsupported file type: ${p.basename(path)}]';
    }
    final file = File(path);
    if (!await file.exists()) return '';
    final size = await file.length();
    if (size <= _textReadCap) {
      return await file.readAsString();
    }
    final raf = await file.open();
    try {
      final bytes = await raf.read(_textReadCap);
      return '${String.fromCharCodes(bytes)}\n\n[truncated after ${_textReadCap ~/ 1024}KB]';
    } finally {
      await raf.close();
    }
  }
}

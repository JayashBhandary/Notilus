import 'dart:io';

import 'package:path/path.dart' as p;

class FileEntry {
  FileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  String get extension => isDirectory ? '' : p.extension(name).toLowerCase();

  bool get isImage {
    const exts = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic'};
    return exts.contains(extension);
  }

  static Future<FileEntry?> from(FileSystemEntity entity) async {
    try {
      final stat = await entity.stat();
      return FileEntry(
        path: entity.path,
        name: p.basename(entity.path),
        isDirectory: stat.type == FileSystemEntityType.directory,
        size: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      return null;
    }
  }
}

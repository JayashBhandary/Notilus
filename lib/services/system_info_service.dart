import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_service.dart';

class DiskUsage {
  DiskUsage({
    required this.name,
    required this.path,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    this.isRoot = false,
  });

  final String name;
  final String path;
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;
  final bool isRoot;

  double get usedFraction =>
      totalBytes <= 0 ? 0 : (usedBytes / totalBytes).clamp(0.0, 1.0);
}

class CategoryBreakdown {
  CategoryBreakdown({
    required this.label,
    required this.path,
    required this.images,
    required this.videos,
    required this.audio,
    required this.documents,
    required this.code,
    required this.other,
    required this.totalBytes,
  });

  final String label;
  final String path;
  final int images;
  final int videos;
  final int audio;
  final int documents;
  final int code;
  final int other;
  final int totalBytes;

  int get totalFiles => images + videos + audio + documents + code + other;
}

class SystemInfoService {
  SystemInfoService(this._fileService);

  final FileService _fileService;

  Future<List<DiskUsage>> diskUsages() async {
    if (Platform.isMacOS || Platform.isLinux) {
      return _readDf();
    }
    if (Platform.isWindows) {
      return _readWindowsDrives();
    }
    return const [];
  }

  Future<DiskUsage?> rootUsage() async {
    final all = await diskUsages();
    for (final d in all) {
      if (d.isRoot) return d;
    }
    return all.isEmpty ? null : all.first;
  }

  Future<List<DiskUsage>> _readDf() async {
    try {
      final res = await Process.run('df', ['-k']);
      if (res.exitCode != 0) return const [];
      final lines = (res.stdout as String).split('\n');
      final usages = <DiskUsage>[];
      for (final line in lines.skip(1)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;
        // df -k columns: filesystem, 1K-blocks, used, available, capacity, mounted-on
        // mount-point is everything from index 5 to end (handle paths with spaces).
        final blocks = int.tryParse(parts[1]);
        final used = int.tryParse(parts[2]);
        final avail = int.tryParse(parts[3]);
        if (blocks == null || used == null || avail == null) continue;
        final mountIndex = _findMountIndex(parts);
        if (mountIndex < 0) continue;
        final mount = parts.sublist(mountIndex).join(' ');
        final keep = _isInterestingMount(mount, parts[0]);
        if (!keep) continue;

        usages.add(DiskUsage(
          name: _mountDisplayName(mount),
          path: mount,
          totalBytes: blocks * 1024,
          usedBytes: used * 1024,
          freeBytes: avail * 1024,
          isRoot: mount == '/',
        ));
      }
      // Dedupe by path (df can list aliased mounts) and sort root first.
      final seen = <String>{};
      final unique = <DiskUsage>[];
      for (final u in usages) {
        if (seen.add(u.path)) unique.add(u);
      }
      unique.sort((a, b) {
        if (a.isRoot != b.isRoot) return a.isRoot ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return unique;
    } catch (_) {
      return const [];
    }
  }

  int _findMountIndex(List<String> parts) {
    for (var i = 5; i < parts.length; i++) {
      if (parts[i].startsWith('/')) return i;
    }
    return -1;
  }

  bool _isInterestingMount(String mount, String fs) {
    if (mount == '/') return true;
    if (mount.startsWith('/Volumes/')) return true;
    if (mount.startsWith('/media/')) return true;
    if (mount.startsWith('/mnt/')) return true;
    // Skip overlay/devfs/etc.
    return false;
  }

  String _mountDisplayName(String mount) {
    if (mount == '/') return 'Macintosh HD';
    return p.basename(mount);
  }

  Future<List<DiskUsage>> _readWindowsDrives() async {
    final usages = <DiskUsage>[];
    // wmic was removed from default Windows installs (11 24H2+); use PowerShell.
    // DriveType 2 = removable, 3 = fixed local disk.
    const psCmd =
        r"Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 or DriveType=3' "
        r"| ForEach-Object { $_.DeviceID + '|' + $_.Size + '|' + $_.FreeSpace }";
    try {
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psCmd],
      );
      if (res.exitCode != 0) return const [];
      final lines = (res.stdout as String).split('\n');
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final cells = line.split('|');
        if (cells.length < 3) continue;
        final name = cells[0];
        final size = int.tryParse(cells[1]);
        final free = int.tryParse(cells[2]);
        if (name.isEmpty || size == null || free == null || size <= 0) continue;
        usages.add(DiskUsage(
          name: name,
          path: '$name\\',
          totalBytes: size,
          usedBytes: size - free,
          freeBytes: free,
          isRoot: name.toUpperCase() == 'C:',
        ));
      }
      usages.sort((a, b) {
        if (a.isRoot != b.isRoot) return a.isRoot ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    } catch (_) {}
    return usages;
  }

  /// Walks [path] (one level deep) and buckets entries by kind.
  /// Returns a quick snapshot — does not recurse.
  Future<CategoryBreakdown> shallowBreakdown(String label, String path) async {
    final result = await _fileService.listDirectory(path);
    int images = 0, videos = 0, audio = 0, docs = 0, code = 0, other = 0;
    int total = 0;
    for (final e in result.entries) {
      if (e.isDirectory) continue;
      total += e.size;
      final ext = e.extension;
      if (_imgExt.contains(ext)) {
        images++;
      } else if (_vidExt.contains(ext)) {
        videos++;
      } else if (_audExt.contains(ext)) {
        audio++;
      } else if (_docExt.contains(ext)) {
        docs++;
      } else if (_codeExt.contains(ext)) {
        code++;
      } else {
        other++;
      }
    }
    return CategoryBreakdown(
      label: label,
      path: path,
      images: images,
      videos: videos,
      audio: audio,
      documents: docs,
      code: code,
      other: other,
      totalBytes: total,
    );
  }

  static const _imgExt = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tiff'
  };
  static const _vidExt = {
    '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v'
  };
  static const _audExt = {
    '.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg'
  };
  static const _docExt = {
    '.pdf', '.docx', '.doc', '.txt', '.md', '.rtf', '.xls', '.xlsx',
    '.ppt', '.pptx', '.csv', '.epub'
  };
  static const _codeExt = {
    '.dart', '.py', '.js', '.ts', '.tsx', '.jsx', '.go', '.rs', '.c',
    '.cpp', '.h', '.hpp', '.java', '.kt', '.swift', '.sh', '.json',
    '.yaml', '.yml', '.html', '.css', '.xml'
  };
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  double size = bytes.toDouble();
  var idx = 0;
  while (size >= 1024 && idx < units.length - 1) {
    size /= 1024;
    idx++;
  }
  final precision = (size >= 100 || idx <= 1) ? 0 : (size >= 10 ? 1 : 2);
  return '${size.toStringAsFixed(precision)} ${units[idx]}';
}


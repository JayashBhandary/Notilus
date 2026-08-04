import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

import 'file_service.dart';

/// How close to full a volume is. Thresholds live here rather than in the
/// widget so the AI prompt, the badge and the gauge colour can't drift apart.
enum DiskHealth { healthy, filling, critical }

class DiskUsage {
  DiskUsage({
    required this.name,
    required this.path,
    required this.totalBytes,
    required this.usedBytes,
    required this.freeBytes,
    this.isRoot = false,
    this.isRemovable = false,
  });

  final String name;
  final String path;
  final int totalBytes;
  final int usedBytes;
  final int freeBytes;
  final bool isRoot;

  /// External/removable media (USB stick, SD card, mounted volume). Drives the
  /// icon and lets the summary exclude them from "this machine" totals.
  final bool isRemovable;

  double get usedFraction =>
      totalBytes <= 0 ? 0 : (usedBytes / totalBytes).clamp(0.0, 1.0);

  DiskHealth get health {
    if (usedFraction >= 0.9) return DiskHealth.critical;
    if (usedFraction >= 0.75) return DiskHealth.filling;
    return DiskHealth.healthy;
  }
}

/// The buckets a shallow folder scan sorts files into.
enum FileCategory {
  images('Images'),
  videos('Videos'),
  audio('Audio'),
  documents('Docs'),
  code('Code'),
  other('Other');

  const FileCategory(this.label);
  final String label;
}

/// Files *and* bytes per bucket. Counts alone are misleading on a storage
/// screen — 400 source files can be smaller than one video.
class CategorySlice {
  const CategorySlice({this.files = 0, this.bytes = 0});

  final int files;
  final int bytes;

  CategorySlice add(int size) =>
      CategorySlice(files: files + 1, bytes: bytes + size);
}

class CategoryBreakdown {
  CategoryBreakdown({
    required this.label,
    required this.path,
    required this.slices,
    this.error,
  });

  /// A folder that couldn't be read (missing, or permission denied).
  CategoryBreakdown.failed({
    required this.label,
    required this.path,
    required this.error,
  }) : slices = const {};

  final String label;
  final String path;
  final Map<FileCategory, CategorySlice> slices;
  final String? error;

  CategorySlice slice(FileCategory c) => slices[c] ?? const CategorySlice();

  int get totalFiles =>
      slices.values.fold(0, (sum, s) => sum + s.files);

  int get totalBytes =>
      slices.values.fold(0, (sum, s) => sum + s.bytes);

  /// Buckets with at least one file, largest first by [byBytes] or by count.
  List<(FileCategory, CategorySlice)> ranked({required bool byBytes}) {
    final out = [
      for (final e in slices.entries)
        if (e.value.files > 0) (e.key, e.value),
    ];
    out.sort((a, b) => byBytes
        ? b.$2.bytes.compareTo(a.$2.bytes)
        : b.$2.files.compareTo(a.$2.files));
    return out;
  }
}

class SystemInfoService {
  SystemInfoService(this._fileService);

  final FileService _fileService;

  /// A stale network mount makes `df` block indefinitely; the same is true of a
  /// PowerShell cold start on a busy machine. Cap both so the page can render
  /// an empty state instead of spinning forever.
  static const _probeTimeout = Duration(seconds: 8);

  Future<List<DiskUsage>> diskUsages() async {
    // dart:io compiles on web but every Platform/Process member throws, so the
    // guard has to come before any of them is touched.
    if (kIsWeb) return const [];
    if (Platform.isMacOS || Platform.isLinux || Platform.isAndroid) {
      return _readDf();
    }
    if (Platform.isWindows) {
      return _readWindowsDrives();
    }
    // iOS sandboxes the filesystem and forbids spawning processes.
    return const [];
  }

  Future<List<DiskUsage>> _readDf() async {
    try {
      final res = await Process.run('df', _dfArgs()).timeout(_probeTimeout);
      if (res.exitCode != 0) return const [];
      final lines = (res.stdout as String).split('\n');
      final usages = <DiskUsage>[];
      for (final line in lines.skip(1)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;
        // df -k columns: filesystem, 1K-blocks, used, available, capacity,
        // [macOS: iused, ifree, %iused,] mounted-on. The mount point is
        // everything from the first path-looking column onward, so paths with
        // spaces survive the re-join.
        final blocks = int.tryParse(parts[1]);
        final used = int.tryParse(parts[2]);
        final avail = int.tryParse(parts[3]);
        if (blocks == null || used == null || avail == null) continue;
        if (blocks <= 0) continue;
        final mountIndex = _findMountIndex(parts);
        if (mountIndex < 0) continue;
        final mount = parts.sublist(mountIndex).join(' ');
        if (!_isInterestingMount(mount, parts[0])) continue;

        usages.add(DiskUsage(
          name: _mountDisplayName(mount),
          path: mount,
          totalBytes: blocks * 1024,
          usedBytes: used * 1024,
          freeBytes: avail * 1024,
          isRoot: mount == '/',
          isRemovable: mount != '/' && !mount.startsWith('/home'),
        ));
      }
      return _dedupeAndSort(usages);
    } catch (_) {
      // Includes TimeoutException — an unreachable mount shouldn't take the
      // whole page down.
      return const [];
    }
  }

  List<String> _dfArgs() {
    // -x (exclude by fs type) is GNU coreutils only: BSD/macOS df and
    // Android's toybox df both reject it, so those fall back to the
    // mount-path filter alone.
    if (Platform.isLinux) {
      return const [
        '-k',
        '-x', 'tmpfs',
        '-x', 'devtmpfs',
        '-x', 'squashfs',
        '-x', 'overlay',
        '-x', 'efivarfs',
        '-x', 'ramfs',
      ];
    }
    return const ['-k'];
  }

  int _findMountIndex(List<String> parts) {
    for (var i = 5; i < parts.length; i++) {
      if (parts[i].startsWith('/')) return i;
    }
    return -1;
  }

  bool _isInterestingMount(String mount, String device) {
    // Snap packages mount one squashfs image per revision under /snap; on a
    // normal desktop that's dozens of 100%-full "drives".
    if (device.startsWith('/dev/loop')) return false;
    if (mount.startsWith('/snap') || mount.startsWith('/var/snap')) {
      return false;
    }
    if (mount == '/') return true;
    // A separate /home partition is the user's real storage, not a peripheral.
    if (mount == '/home' || mount.startsWith('/home/')) return true;
    if (mount.startsWith('/Volumes/')) return true;
    // /media/<user>/… on Debian & Ubuntu, /run/media/<user>/… on Fedora, Arch
    // and anything else using udisks2 directly.
    if (mount.startsWith('/media/')) return true;
    if (mount.startsWith('/run/media/')) return true;
    if (mount.startsWith('/mnt/')) return true;
    // Android's primary volume.
    if (mount == '/storage/emulated/0' || mount == '/data') return true;
    return false;
  }

  String _mountDisplayName(String mount) {
    if (mount == '/') {
      if (Platform.isMacOS) return 'Macintosh HD';
      if (Platform.isAndroid) return 'Internal storage';
      return 'System';
    }
    final base = p.basename(mount);
    return base.isEmpty ? mount : base;
  }

  Future<List<DiskUsage>> _readWindowsDrives() async {
    // wmic was removed from default Windows installs (11 24H2+), so this goes
    // through CIM. DriveType 2 = removable, 3 = fixed local disk.
    const psCmd =
        r"Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 or DriveType=3' "
        r"| ForEach-Object { $_.DeviceID + '|' + $_.Size + '|' + $_.FreeSpace "
        r"+ '|' + $_.DriveType + '|' + $_.VolumeName }";
    try {
      final res = await Process.run(
        'powershell',
        const ['-NoProfile', '-NonInteractive', '-Command', psCmd],
      ).timeout(_probeTimeout);
      if (res.exitCode != 0) return const [];
      final usages = <DiskUsage>[];
      for (final raw in (res.stdout as String).split('\n')) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final cells = line.split('|');
        if (cells.length < 3) continue;
        final id = cells[0];
        final size = int.tryParse(cells[1]);
        final free = int.tryParse(cells[2]);
        // An empty card reader or ejected disc reports a null Size, which
        // parses to null here and drops the row.
        if (id.isEmpty || size == null || free == null || size <= 0) continue;
        final driveType = cells.length > 3 ? int.tryParse(cells[3]) : null;
        final label = cells.length > 4 ? cells.sublist(4).join('|').trim() : '';
        usages.add(DiskUsage(
          name: label.isEmpty ? id : '$label ($id)',
          path: '$id\\',
          totalBytes: size,
          usedBytes: size - free,
          freeBytes: free,
          isRoot: id.toUpperCase() == 'C:',
          isRemovable: driveType == 2,
        ));
      }
      return _dedupeAndSort(usages);
    } catch (_) {
      return const [];
    }
  }

  /// Drops aliased mounts (`df` can list the same path twice) and puts the
  /// system volume first, then everything else alphabetically.
  List<DiskUsage> _dedupeAndSort(List<DiskUsage> usages) {
    final seen = <String>{};
    final unique = <DiskUsage>[];
    for (final u in usages) {
      if (seen.add(u.path)) unique.add(u);
    }
    unique.sort((a, b) {
      if (a.isRoot != b.isRoot) return a.isRoot ? -1 : 1;
      if (a.isRemovable != b.isRemovable) return a.isRemovable ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return unique;
  }

  /// Walks [path] (one level deep) and buckets entries by kind.
  /// Returns a quick snapshot — does not recurse.
  Future<CategoryBreakdown> shallowBreakdown(String label, String path) async {
    final result = await _fileService.listDirectory(path);
    if (result.error != null) {
      return CategoryBreakdown.failed(
        label: label,
        path: path,
        error: result.error,
      );
    }
    final slices = <FileCategory, CategorySlice>{};
    for (final e in result.entries) {
      if (e.isDirectory) continue;
      // FileEntry.extension is already lower-cased and dot-prefixed.
      final category = _extCategory[e.extension] ?? FileCategory.other;
      slices[category] = (slices[category] ?? const CategorySlice()).add(e.size);
    }
    return CategoryBreakdown(label: label, path: path, slices: slices);
  }

  /// Flat extension → bucket lookup. One map beats six sets plus an if-chain:
  /// an extension can't accidentally land in two buckets. `final`, not `const`
  /// — collection-`for` isn't allowed in a const literal.
  static final Map<String, FileCategory> _extCategory = {
    for (final e in [
      '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.heif',
      '.tiff', '.svg', '.avif',
    ])
      e: FileCategory.images,
    for (final e in [
      '.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v', '.wmv',
    ])
      e: FileCategory.videos,
    for (final e in [
      '.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.aiff',
    ])
      e: FileCategory.audio,
    for (final e in [
      '.pdf', '.docx', '.doc', '.txt', '.md', '.rtf', '.xls', '.xlsx',
      '.ppt', '.pptx', '.csv', '.epub', '.pages', '.numbers', '.key',
    ])
      e: FileCategory.documents,
    for (final e in [
      '.dart', '.py', '.js', '.ts', '.tsx', '.jsx', '.go', '.rs', '.c',
      '.cpp', '.h', '.hpp', '.java', '.kt', '.swift', '.sh', '.json',
      '.yaml', '.yml', '.html', '.css', '.xml', '.rb', '.php', '.sql',
      '.toml',
    ])
      e: FileCategory.code,
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

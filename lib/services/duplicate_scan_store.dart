import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'duplicate_finder_service.dart';

/// A previously-saved scan, restored from disk.
class SavedScan {
  SavedScan({required this.savedAt, required this.groups});
  final DateTime savedAt;
  final List<DuplicateGroup> groups;
}

/// Persists the most recent duplicate scan to a JSON file in the app support
/// directory, so reopening the app doesn't force a rescan. Results can be
/// large, so a file is used rather than SharedPreferences.
class DuplicateScanStore {
  static const _fileName = 'duplicate_scan.json';

  Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File(p.join(base.path, _fileName));
  }

  Future<void> save(List<DuplicateGroup> groups, DateTime savedAt) async {
    try {
      final file = await _file();
      final payload = {
        'savedAt': savedAt.millisecondsSinceEpoch,
        'groups': groups.map((g) => g.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {
      // Non-fatal — saving the cache is best-effort.
    }
  }

  /// Loads and *validates* the saved scan: files that no longer exist are
  /// dropped, and any group left with fewer than two copies is removed. Content
  /// edits are not re-checked (that would require rehashing). Returns null if
  /// nothing was saved or the file is unreadable.
  Future<SavedScan?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(
        (map['savedAt'] as num?)?.toInt() ?? 0,
      );
      final rawGroups = (map['groups'] as List? ?? const [])
          .map((e) => DuplicateGroup.fromJson(e as Map<String, dynamic>));

      final validated = <DuplicateGroup>[];
      for (final g in rawGroups) {
        final present = <dynamic>[];
        for (final f in g.files) {
          if (await File(f.path).exists()) present.add(f);
        }
        if (present.length < 2) continue;
        validated.add(DuplicateGroup(
          hash: g.hash,
          size: g.size,
          files: List.castFrom(present),
        ));
      }
      validated.sort((a, b) => b.reclaimableBytes.compareTo(a.reclaimableBytes));
      return SavedScan(savedAt: savedAt, groups: validated);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

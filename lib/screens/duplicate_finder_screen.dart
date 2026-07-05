import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../services/duplicate_finder_service.dart';
import '../services/duplicate_scan_store.dart';
import '../services/file_actions_service.dart';
import '../services/settings_store.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../theme.dart';
import '../widgets/skeleton.dart';
import 'file_preview_screen.dart';

/// File-type categories the scan can be narrowed to.
enum _FileType { all, images, videos, audio, documents }

const Map<_FileType, ({String label, Set<String>? exts})> _fileTypeSpecs = {
  _FileType.all: (label: 'All files', exts: null),
  _FileType.images: (
    label: 'Images',
    exts: {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tiff'},
  ),
  _FileType.videos: (
    label: 'Videos',
    exts: {'.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v'},
  ),
  _FileType.audio: (
    label: 'Audio',
    exts: {'.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg'},
  ),
  _FileType.documents: (
    label: 'Documents',
    exts: {
      '.pdf', '.docx', '.doc', '.txt', '.md', '.rtf', '.xls', '.xlsx',
      '.ppt', '.pptx', '.csv', '.epub',
    },
  ),
};

/// Which copy to keep when bulk-cleaning a group (the rest go to Trash).
enum _KeepStrategy { newest, oldest, shortestPath }

const Map<_KeepStrategy, String> _keepStrategyLabels = {
  _KeepStrategy.newest: 'Newest',
  _KeepStrategy.oldest: 'Oldest',
  _KeepStrategy.shortestPath: 'Shortest path',
};

/// A scan target the user can toggle on/off before running a scan.
class _ScanTarget {
  _ScanTarget({
    required this.label,
    required this.path,
    required this.icon,
    this.selected = false,
  });
  final String label;
  final String path;
  final IconData icon;
  bool selected;
}

/// Embeddable Duplicate Finder page. Rendered inside the app's central
/// content pane (not a full-screen route).
class DuplicateFinderView extends StatefulWidget {
  const DuplicateFinderView({super.key});

  @override
  State<DuplicateFinderView> createState() => _DuplicateFinderViewState();
}

class _DuplicateFinderViewState extends State<DuplicateFinderView> {
  final _actions = FileActionsService();
  final _store = SettingsStore();
  final _scanStore = DuplicateScanStore();
  final _customExcludeController = TextEditingController();
  List<_ScanTarget> _targets = [];
  bool _targetsBuilt = false;

  // Saved-scan state.
  DateTime? _lastScanAt;
  bool _restoredFromCache = false;

  // Filters.
  bool _skipDevFolders = true;
  bool _skipBundles = true;
  bool _includeHidden = false;
  _FileType _fileType = _FileType.all;
  final Set<String> _customExcludes = {};
  _KeepStrategy _keepStrategy = _KeepStrategy.newest;

  DuplicateFinderService? _service;
  bool _scanning = false;
  ScanProgress? _progress;
  List<DuplicateGroup> _groups = [];
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _restoreSavedScan();
  }

  Future<void> _restoreSavedScan() async {
    final saved = await _scanStore.load();
    if (!mounted || saved == null || saved.groups.isEmpty) return;
    // Don't clobber a scan the user kicked off while we were loading.
    if (_scanning || _hasScanned) return;
    setState(() {
      _groups = saved.groups;
      _lastScanAt = saved.savedAt;
      _hasScanned = true;
      _restoredFromCache = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_targetsBuilt) {
      _buildTargets();
      _targetsBuilt = true;
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await _store.getDuplicateFinderPrefs();
    if (!mounted || prefs.isEmpty) return;
    setState(() {
      _skipDevFolders = prefs['skipDevFolders'] as bool? ?? _skipDevFolders;
      _skipBundles = prefs['skipBundles'] as bool? ?? _skipBundles;
      _includeHidden = prefs['includeHidden'] as bool? ?? _includeHidden;
      final ft = prefs['fileType'] as int?;
      if (ft != null && ft >= 0 && ft < _FileType.values.length) {
        _fileType = _FileType.values[ft];
      }
      final ks = prefs['keepStrategy'] as int?;
      if (ks != null && ks >= 0 && ks < _KeepStrategy.values.length) {
        _keepStrategy = _KeepStrategy.values[ks];
      }
      final custom = prefs['customExcludes'] as List?;
      if (custom != null) {
        _customExcludes
          ..clear()
          ..addAll(custom.map((e) => e.toString()));
      }
    });
  }

  void _savePrefs() {
    _store.setDuplicateFinderPrefs({
      'skipDevFolders': _skipDevFolders,
      'skipBundles': _skipBundles,
      'includeHidden': _includeHidden,
      'fileType': _fileType.index,
      'keepStrategy': _keepStrategy.index,
      'customExcludes': _customExcludes.toList(),
    });
  }

  @override
  void dispose() {
    _service?.cancel();
    _customExcludeController.dispose();
    super.dispose();
  }

  void _addCustomExclude() {
    final raw = _customExcludeController.text;
    // Accept comma/space/newline-separated names at once.
    final names = raw
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty);
    if (names.isEmpty) return;
    setState(() {
      _customExcludes.addAll(names);
      _customExcludeController.clear();
    });
    _savePrefs();
  }

  void _buildTargets() {
    final browser = context.read<BrowserProvider>();
    final targets = <_ScanTarget>[];
    // Drives are checked by default — this is the "all drives" scope.
    for (final d in browser.drives) {
      targets.add(_ScanTarget(
        label: d.name,
        path: d.path,
        icon: d.isRoot
            ? CupertinoIcons.device_laptop
            : CupertinoIcons.archivebox_fill,
        selected: true,
      ));
    }
    // Shortcut folders let users narrow the scan without a native picker.
    const shortcutIcons = {
      'Home': CupertinoIcons.house_fill,
      'Desktop': CupertinoIcons.desktopcomputer,
      'Documents': CupertinoIcons.doc_text_fill,
      'Downloads': CupertinoIcons.arrow_down_circle_fill,
    };
    final seenPaths = targets.map((t) => t.path).toSet();
    browser.shortcuts.forEach((name, path) {
      if (path == null || path.isEmpty) return;
      if (!seenPaths.add(path)) return;
      targets.add(_ScanTarget(
        label: name,
        path: path,
        icon: shortcutIcons[name] ?? CupertinoIcons.folder_fill,
      ));
    });
    _targets = targets;
  }

  Future<void> _startScan() async {
    final roots = _targets
        .where((t) => t.selected)
        .map((t) => t.path)
        .toList();
    if (roots.isEmpty) return;

    final service = DuplicateFinderService();
    setState(() {
      _service = service;
      _scanning = true;
      _hasScanned = true;
      _groups = [];
      _progress = ScanProgress(
        phase: 'Scanning',
        filesSeen: 0,
        filesHashed: 0,
        hashTotal: 0,
      );
    });

    final excluded = <String>{
      if (_skipDevFolders) ...DuplicateFinderService.defaultExcludedDirs,
      ..._customExcludes,
    };
    final groups = await service.scan(
      roots: roots,
      excludedDirNames: excluded,
      allowedExtensions: _fileTypeSpecs[_fileType]!.exts,
      skipHidden: !_includeHidden,
      skipBundles: _skipBundles,
      onProgress: (prog) {
        if (mounted && !service.isCancelled) {
          setState(() => _progress = prog);
        }
      },
    );

    if (!mounted) return;
    // A cancelled scan resolves with an empty list — don't overwrite results
    // or flip into the "no duplicates found" state.
    if (service.isCancelled) {
      setState(() {
        _scanning = false;
        _hasScanned = false;
        _service = null;
      });
      return;
    }
    final now = DateTime.now();
    setState(() {
      _scanning = false;
      _groups = groups;
      _service = null;
      _lastScanAt = now;
      _restoredFromCache = false;
    });
    _scanStore.save(groups, now);
  }

  /// Re-persist the current groups (after a trash/cleanup) so the saved cache
  /// stays in sync. Keeps the original scan timestamp.
  void _persistCurrent() {
    _scanStore.save(_groups, _lastScanAt ?? DateTime.now());
  }

  void _cancelScan() {
    _service?.cancel();
    setState(() => _scanning = false);
  }

  /// Index of the copy to keep in [group] under the current strategy.
  int _keepIndex(DuplicateGroup group) {
    final files = group.files;
    var best = 0;
    for (var i = 1; i < files.length; i++) {
      final f = files[i];
      final b = files[best];
      final keepThis = switch (_keepStrategy) {
        _KeepStrategy.newest => f.modified.isAfter(b.modified),
        _KeepStrategy.oldest => f.modified.isBefore(b.modified),
        _KeepStrategy.shortestPath => f.path.length < b.path.length,
      };
      if (keepThis) best = i;
    }
    return best;
  }

  Future<void> _cleanupGroup(DuplicateGroup group) async {
    await _cleanup([group], scope: 'this group');
  }

  Future<void> _cleanupAll() async {
    await _cleanup(List.of(_groups), scope: 'all groups');
  }

  /// Trashes every copy except the kept one across [groups].
  Future<void> _cleanup(List<DuplicateGroup> groups, {required String scope}) async {
    final victims = <DuplicateGroup, List<FileEntry>>{};
    var fileCount = 0;
    var reclaim = 0;
    for (final g in groups) {
      final keep = _keepIndex(g);
      final list = <FileEntry>[];
      for (var i = 0; i < g.files.length; i++) {
        if (i != keep) list.add(g.files[i]);
      }
      if (list.isEmpty) continue;
      victims[g] = list;
      fileCount += list.length;
      reclaim += g.size * list.length;
    }
    if (fileCount == 0) return;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Move duplicates to Trash?'),
        content: Text(
          '\nThis moves $fileCount file${fileCount == 1 ? '' : 's'} to the '
          'Trash across $scope, keeping the ${_keepStrategyLabels[_keepStrategy]!.toLowerCase()} '
          'copy in each group.\n\nReclaims about ${formatBytes(reclaim)}.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Trash $fileCount'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Trash the whole selection in one batch so macOS plays the Trash sound
    // once for the cleanup instead of once per file.
    final allVictims = victims.values.expand((l) => l).toList();
    final failedPaths = await _actions.trashAll(allVictims);
    for (final entry in victims.entries) {
      final group = entry.key;
      for (final file in entry.value) {
        if (!failedPaths.contains(file.path)) {
          group.files.removeWhere((f) => f.path == file.path);
        }
      }
    }
    final failures = failedPaths.length;
    if (!mounted) return;
    setState(() {
      _groups.removeWhere((g) => g.files.length < 2);
    });
    _persistCurrent();
    if (failures > 0) {
      await _showError(
        '$failures file${failures == 1 ? '' : 's'} couldn\'t be moved to '
        'Trash (they were kept).',
      );
    }
  }

  Future<void> _reveal(FileEntry entry) async {
    final ok = await _actions.revealInOs(entry);
    if (!ok && mounted) {
      await _showError('Couldn\'t reveal this file on this platform.');
    }
  }

  _GroupCard _groupCardFor(DuplicateGroup g, AppPalette palette) => _GroupCard(
        group: g,
        keepIndex: _keepIndex(g),
        palette: palette,
        onReveal: _reveal,
        onTrash: (entry) => _trash(g, entry),
        onOpen: (entry) => _openPreview(g, entry),
        onCleanupGroup: () => _cleanupGroup(g),
      );

  /// Builds one lazily-materialised row of the group grid: up to [columns]
  /// cards side by side. Only rows scrolled into view are built, so off-screen
  /// thumbnails never decode — this is what keeps the page fast on big scans.
  Widget _buildGroupRow(int rowIndex, int columns, AppPalette palette) {
    if (columns <= 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: RepaintBoundary(child: _groupCardFor(_groups[rowIndex], palette)),
      );
    }
    final start = rowIndex * columns;
    final children = <Widget>[];
    for (var c = 0; c < columns; c++) {
      if (c > 0) children.add(const SizedBox(width: 10));
      final idx = start + c;
      children.add(Expanded(
        child: idx < _groups.length
            ? RepaintBoundary(child: _groupCardFor(_groups[idx], palette))
            : const SizedBox.shrink(),
      ));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  /// Opens the in-app Quick-Look viewer, seeded with all copies in the group so
  /// the user can flip between them without leaving the app.
  void _openPreview(DuplicateGroup group, FileEntry entry) {
    final idx = group.files.indexWhere((f) => f.path == entry.path);
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => FilePreviewScreen(
          files: group.files,
          initialIndex: idx < 0 ? 0 : idx,
        ),
      ),
    );
  }

  Future<void> _trash(DuplicateGroup group, FileEntry entry) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Move to Trash?'),
        content: Text(
          '\n${entry.name}\n\nThe other cop${group.files.length > 2 ? 'ies' : 'y'} '
          'in this group will be kept.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ok = await _actions.trash(entry);
    if (!mounted) return;
    if (!ok) {
      await _showError('Couldn\'t move "${entry.name}" to Trash.');
      return;
    }
    setState(() {
      group.files.removeWhere((f) => f.path == entry.path);
      // A group with a single remaining copy is no longer a duplicate.
      if (group.files.length < 2) {
        _groups.removeWhere((g) => g.hash == group.hash && g.size == group.size);
      }
    });
    _persistCurrent();
  }

  Future<void> _showError(String message) async {
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);

    return ColoredBox(
      color: palette.scaffoldBg,
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Responsive column count for the group grid.
            final columns =
                ((constraints.maxWidth - 32) / 364).floor().clamp(1, 4);
            final showGroups =
                !_scanning && _hasScanned && _groups.isNotEmpty;
            final rowCount = columns <= 1
                ? _groups.length
                : (_groups.length + columns - 1) ~/ columns;

            // Header widgets (few, cheap) build eagerly; the group cards are
            // virtualized below so only on-screen thumbnails decode.
            final header = <Widget>[
              _ScopeCard(
                targets: _targets,
                enabled: !_scanning,
                onToggle: (t) => setState(() => t.selected = !t.selected),
                palette: palette,
              ),
              const SizedBox(height: 16),
              _FiltersCard(
                enabled: !_scanning,
                skipDevFolders: _skipDevFolders,
                skipBundles: _skipBundles,
                includeHidden: _includeHidden,
                fileType: _fileType,
                customExcludes: _customExcludes,
                controller: _customExcludeController,
                onToggleDevFolders: (v) {
                  setState(() => _skipDevFolders = v);
                  _savePrefs();
                },
                onToggleBundles: (v) {
                  setState(() => _skipBundles = v);
                  _savePrefs();
                },
                onToggleHidden: (v) {
                  setState(() => _includeHidden = v);
                  _savePrefs();
                },
                onFileType: (t) {
                  setState(() => _fileType = t);
                  _savePrefs();
                },
                onAddCustom: _addCustomExclude,
                onRemoveCustom: (name) {
                  setState(() => _customExcludes.remove(name));
                  _savePrefs();
                },
                palette: palette,
              ),
              const SizedBox(height: 16),
              if (_scanning)
                _ProgressCard(
                    progress: _progress, onCancel: _cancelScan, palette: palette)
              else
                _ScanButton(
                  enabled: _targets.any((t) => t.selected),
                  onPressed: _startScan,
                  palette: palette,
                ),
              const SizedBox(height: 16),
              // While scanning, sketch a few result cards so the area below the
              // progress bar reads as "results loading" instead of empty.
              if (_scanning) ...[
                _SkeletonGroupCard(palette: palette),
                const SizedBox(height: 12),
                _SkeletonGroupCard(palette: palette),
                const SizedBox(height: 12),
                _SkeletonGroupCard(palette: palette),
              ],
              if (!_scanning && _hasScanned) ...[
                _ResultsHeader(groups: _groups, palette: palette),
                if (_lastScanAt != null) ...[
                  const SizedBox(height: 6),
                  _SavedBanner(
                    savedAt: _lastScanAt!,
                    restored: _restoredFromCache,
                    palette: palette,
                  ),
                ],
                const SizedBox(height: 8),
                if (_groups.isEmpty)
                  _EmptyResults(palette: palette)
                else
                  _CleanupBar(
                    keepStrategy: _keepStrategy,
                    onKeepStrategy: (s) {
                      setState(() => _keepStrategy = s);
                      _savePrefs();
                    },
                    onCleanupAll: _cleanupAll,
                    palette: palette,
                  ),
                const SizedBox(height: 10),
              ],
            ];

            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, showGroups ? 0 : 24),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(header),
                  ),
                ),
                if (showGroups)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, rowIndex) =>
                            _buildGroupRow(rowIndex, columns, palette),
                        childCount: rowCount,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child, required this.palette});
  final Widget child;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.palette});
  final String text;
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.5,
        fontWeight: FontWeight.w600,
        color: palette.subtleText,
      ),
    );
  }
}

class _ScopeCard extends StatelessWidget {
  const _ScopeCard({
    required this.targets,
    required this.enabled,
    required this.onToggle,
    required this.palette,
  });
  final List<_ScanTarget> targets;
  final bool enabled;
  final ValueChanged<_ScanTarget> onToggle;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel('Where to look', palette: palette),
          const SizedBox(height: 4),
          Text(
            'Duplicates are matched by exact content (size + SHA-256), '
            'regardless of file name.',
            style: TextStyle(fontSize: 11.5, color: palette.subtleText, height: 1.4),
          ),
          const SizedBox(height: 10),
          if (targets.isEmpty)
            Text(
              'No drives or folders detected.',
              style: TextStyle(fontSize: 12, color: palette.subtleText),
            )
          else
            ...targets.map((t) => _TargetRow(
                  target: t,
                  enabled: enabled,
                  onToggle: () => onToggle(t),
                  palette: palette,
                )),
        ],
      ),
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({
    required this.target,
    required this.enabled,
    required this.onToggle,
    required this.palette,
  });
  final _ScanTarget target;
  final bool enabled;
  final VoidCallback onToggle;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onToggle : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(
                target.selected
                    ? CupertinoIcons.checkmark_square_fill
                    : CupertinoIcons.square,
                size: 20,
                color: target.selected ? palette.accent : palette.subtleText,
              ),
              const SizedBox(width: 10),
              Icon(target.icon, size: 15, color: palette.folderIcon),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: palette.text,
                      ),
                    ),
                    Text(
                      target.path,
                      style: TextStyle(fontSize: 10.5, color: palette.subtleText),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FiltersCard extends StatelessWidget {
  const _FiltersCard({
    required this.enabled,
    required this.skipDevFolders,
    required this.skipBundles,
    required this.includeHidden,
    required this.fileType,
    required this.customExcludes,
    required this.controller,
    required this.onToggleDevFolders,
    required this.onToggleBundles,
    required this.onToggleHidden,
    required this.onFileType,
    required this.onAddCustom,
    required this.onRemoveCustom,
    required this.palette,
  });

  final bool enabled;
  final bool skipDevFolders;
  final bool skipBundles;
  final bool includeHidden;
  final _FileType fileType;
  final Set<String> customExcludes;
  final TextEditingController controller;
  final ValueChanged<bool> onToggleDevFolders;
  final ValueChanged<bool> onToggleBundles;
  final ValueChanged<bool> onToggleHidden;
  final ValueChanged<_FileType> onFileType;
  final VoidCallback onAddCustom;
  final ValueChanged<String> onRemoveCustom;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !enabled,
        child: _Card(
          palette: palette,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel('Filters', palette: palette),
              const SizedBox(height: 10),
              _SwitchRow(
                title: 'Skip dev & build folders',
                subtitle:
                    'node_modules, venv, __pycache__, .git, build, dist, '
                    'target, Pods, vendor, .cache …',
                value: skipDevFolders,
                onChanged: onToggleDevFolders,
                palette: palette,
              ),
              const SizedBox(height: 6),
              _SwitchRow(
                title: 'Treat app bundles & packages as one item',
                subtitle: '.app, .framework, .photoslibrary … aren\'t opened '
                    'up — their internal files are ignored.',
                value: skipBundles,
                onChanged: onToggleBundles,
                palette: palette,
              ),
              const SizedBox(height: 6),
              _SwitchRow(
                title: 'Include hidden files & folders',
                subtitle: 'Off by default — dot-files and dot-folders are '
                    'skipped. Trash and Recycle Bin are always excluded.',
                value: includeHidden,
                onChanged: onToggleHidden,
                palette: palette,
              ),
              const SizedBox(height: 14),
              Text(
                'File type',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _FileType.values.map((t) {
                  return _FilterChip(
                    label: _fileTypeSpecs[t]!.label,
                    selected: t == fileType,
                    onTap: () => onFileType(t),
                    palette: palette,
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              Text(
                'Also skip folders named',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: CupertinoTextField(
                      controller: controller,
                      placeholder: 'e.g. tmp, cache, .idea',
                      style: TextStyle(fontSize: 13, color: palette.text),
                      placeholderStyle:
                          TextStyle(fontSize: 13, color: palette.subtleText),
                      decoration: BoxDecoration(
                        color: palette.headerBg,
                        border: Border.all(color: palette.divider),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      onSubmitted: (_) => onAddCustom(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    color: palette.headerBg,
                    minimumSize: const Size(0, 36),
                    onPressed: onAddCustom,
                    child: Text(
                      'Add',
                      style: TextStyle(fontSize: 13, color: palette.accent),
                    ),
                  ),
                ],
              ),
              if (customExcludes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: customExcludes.map((name) {
                    return _RemovableChip(
                      label: name,
                      onRemove: () => onRemoveCustom(name),
                      palette: palette,
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.palette,
  });
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                    fontSize: 10.5, color: palette.subtleText, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        CupertinoSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.palette,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? palette.accent : palette.headerBg,
          border: Border.all(
              color: selected ? palette.accent : palette.divider),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? CupertinoColors.white : palette.text,
          ),
        ),
      ),
    );
  }
}

class _RemovableChip extends StatelessWidget {
  const _RemovableChip({
    required this.label,
    required this.onRemove,
    required this.palette,
  });
  final String label;
  final VoidCallback onRemove;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: palette.text),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRemove,
            child: Icon(
              CupertinoIcons.clear_circled_solid,
              size: 15,
              color: palette.subtleText,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton({
    required this.enabled,
    required this.onPressed,
    required this.palette,
  });
  final bool enabled;
  final VoidCallback onPressed;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: CupertinoButton.filled(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        onPressed: enabled ? onPressed : null,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.search, size: 16, color: CupertinoColors.white),
            SizedBox(width: 8),
            Text('Find Duplicates', style: TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.progress,
    required this.onCancel,
    required this.palette,
  });
  final ScanProgress? progress;
  final VoidCallback onCancel;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final prog = progress;
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CupertinoActivityIndicator(radius: 9),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  prog == null
                      ? 'Starting…'
                      : prog.phase == 'Comparing'
                          ? 'Comparing ${prog.filesHashed} / ${prog.hashTotal} candidates'
                          : 'Scanning — ${prog.filesSeen} files found',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: onCancel,
                child: const Text('Cancel', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
          if (prog != null && prog.currentPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              prog.currentPath,
              style: TextStyle(fontSize: 10.5, color: palette.subtleText),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({required this.groups, required this.palette});
  final List<DuplicateGroup> groups;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final reclaimable =
        groups.fold<int>(0, (a, g) => a + g.reclaimableBytes);
    final dupeCount =
        groups.fold<int>(0, (a, g) => a + (g.files.length - 1));
    return Row(
      children: [
        _SectionLabel('Results', palette: palette),
        const Spacer(),
        if (groups.isNotEmpty)
          Text(
            '${groups.length} group${groups.length == 1 ? '' : 's'} • '
            '$dupeCount extra cop${dupeCount == 1 ? 'y' : 'ies'} • '
            '${formatBytes(reclaimable)} reclaimable',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: palette.subtleText,
            ),
          ),
      ],
    );
  }
}

class _SavedBanner extends StatelessWidget {
  const _SavedBanner({
    required this.savedAt,
    required this.restored,
    required this.palette,
  });
  final DateTime savedAt;
  final bool restored;
  final AppPalette palette;

  String _relative() {
    final diff = DateTime.now().difference(savedAt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    }
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final text = restored
        ? 'Loaded saved results from ${_relative()}. Rescan for full accuracy.'
        : 'Last scanned ${_relative()}.';
    return Row(
      children: [
        Icon(
          restored ? CupertinoIcons.clock : CupertinoIcons.checkmark_circle,
          size: 12,
          color: palette.subtleText,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11, color: palette.subtleText),
          ),
        ),
      ],
    );
  }
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.palette});
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: Row(
        children: [
          Icon(CupertinoIcons.checkmark_seal_fill,
              size: 20, color: palette.success),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No duplicate files found in the selected locations.',
              style: TextStyle(fontSize: 13, color: palette.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _CleanupBar extends StatelessWidget {
  const _CleanupBar({
    required this.keepStrategy,
    required this.onKeepStrategy,
    required this.onCleanupAll,
    required this.palette,
  });
  final _KeepStrategy keepStrategy;
  final ValueChanged<_KeepStrategy> onKeepStrategy;
  final VoidCallback onCleanupAll;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Keep the',
                style: TextStyle(fontSize: 12, color: palette.subtleText),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CupertinoSlidingSegmentedControl<_KeepStrategy>(
                  groupValue: keepStrategy,
                  children: {
                    for (final s in _KeepStrategy.values)
                      s: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        child: Text(
                          _keepStrategyLabels[s]!,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                  },
                  onValueChanged: (v) {
                    if (v != null) onKeepStrategy(v);
                  },
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'copy',
                style: TextStyle(fontSize: 12, color: palette.subtleText),
              ),
            ],
          ),
          const SizedBox(height: 10),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 9),
            color: palette.danger,
            onPressed: onCleanupAll,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.delete, size: 15, color: CupertinoColors.white),
                SizedBox(width: 8),
                Text(
                  'Clean up all groups',
                  style: TextStyle(fontSize: 13, color: CupertinoColors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder duplicate-group card shown while a scan is in progress. Static
/// (no shimmer) to avoid adding paint cost during the scan.
class _SkeletonGroupCard extends StatelessWidget {
  const _SkeletonGroupCard({required this.palette});
  final AppPalette palette;
  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SkeletonBlock(width: 70, height: 12),
              Spacer(),
              SkeletonBlock(width: 120, height: 11),
            ],
          ),
          SizedBox(height: 12),
          Row(
            children: [
              SkeletonBlock(width: 72, height: 72, radius: 8),
              SizedBox(width: 8),
              SkeletonBlock(width: 72, height: 72, radius: 8),
              SizedBox(width: 8),
              SkeletonBlock(width: 72, height: 72, radius: 8),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.keepIndex,
    required this.palette,
    required this.onReveal,
    required this.onTrash,
    required this.onOpen,
    required this.onCleanupGroup,
  });
  final DuplicateGroup group;
  final int keepIndex;
  final AppPalette palette;
  final void Function(FileEntry) onReveal;
  final void Function(FileEntry) onTrash;
  final void Function(FileEntry) onOpen;
  final VoidCallback onCleanupGroup;

  @override
  Widget build(BuildContext context) {
    return _Card(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(CupertinoIcons.doc_on_doc_fill,
                  size: 15, color: palette.accent),
              const SizedBox(width: 8),
              Text(
                '${group.files.length} copies',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  '${formatBytes(group.size)} each • '
                  '${formatBytes(group.reclaimableBytes)} reclaimable',
                  style: TextStyle(fontSize: 11, color: palette.subtleText),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
              const SizedBox(width: 4),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                onPressed: onCleanupGroup,
                child: Text(
                  'Trash extras',
                  style: TextStyle(fontSize: 11.5, color: palette.danger),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: group.files.asMap().entries.map((e) {
              return SizedBox(
                width: 150,
                child: _FileTile(
                  entry: e.value,
                  keepHint: e.key == keepIndex,
                  palette: palette,
                  onReveal: () => onReveal(e.value),
                  onTrash: () => onTrash(e.value),
                  onOpen: () => onOpen(e.value),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

/// A compact grid tile for one duplicate copy: a large thumbnail, name,
/// modified date, and compact actions. Tapping the thumbnail opens the viewer.
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.keepHint,
    required this.palette,
    required this.onReveal,
    required this.onTrash,
    required this.onOpen,
  });
  final FileEntry entry;
  final bool keepHint;
  final AppPalette palette;
  final VoidCallback onReveal;
  final VoidCallback onTrash;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final canReveal = Platform.isMacOS;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border.all(
          color: keepHint
              ? palette.success.withValues(alpha: 0.5)
              : palette.divider,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Stack(
              children: [
                _TileThumbnail(entry: entry, palette: palette),
                if (keepHint)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: palette.success,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'keep',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: palette.cardBg.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(CupertinoIcons.eye_fill,
                        size: 11, color: palette.accent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 2),
          Text(
            _formatDate(entry.modified),
            style: TextStyle(fontSize: 9.5, color: palette.subtleText),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _IconAction(
                icon: CupertinoIcons.eye,
                tooltip: 'Preview',
                color: palette.accent,
                onPressed: onOpen,
              ),
              if (canReveal)
                _IconAction(
                  icon: CupertinoIcons.folder,
                  tooltip: 'Reveal in Finder',
                  color: palette.subtleText,
                  onPressed: onReveal,
                ),
              const Spacer(),
              _IconAction(
                icon: CupertinoIcons.delete,
                tooltip: 'Move to Trash',
                color: palette.danger,
                onPressed: onTrash,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-width square-ish thumbnail for a grid tile.
class _TileThumbnail extends StatelessWidget {
  const _TileThumbnail({required this.entry, required this.palette});
  final FileEntry entry;
  final AppPalette palette;

  static const _imageExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tif',
    '.tiff', '.ico',
  };

  IconData _glyphFor(String ext) {
    const video = {'.mp4', '.mov', '.mkv', '.avi', '.webm', '.flv', '.m4v'};
    const audio = {'.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg'};
    const doc = {'.pdf', '.doc', '.docx', '.txt', '.md', '.rtf', '.csv'};
    if (video.contains(ext)) return CupertinoIcons.play_rectangle_fill;
    if (audio.contains(ext)) return CupertinoIcons.music_note;
    if (doc.contains(ext)) return CupertinoIcons.doc_text_fill;
    return CupertinoIcons.doc_fill;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.25,
      child: Container(
        decoration: BoxDecoration(
          color: palette.cardBg,
          border: Border.all(color: palette.divider),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: _imageExts.contains(entry.extension)
            ? Image.file(
                File(entry.path),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: 300,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    Icon(CupertinoIcons.photo, size: 34, color: palette.subtleText),
              )
            : Icon(_glyphFor(entry.extension), size: 34, color: palette.subtleText),
      ),
    );
  }
}

/// Compact human date, e.g. "Jul 4, 2026".
String _formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(30, 30),
      onPressed: onPressed,
      child: Icon(icon, size: 17, color: color),
    );
  }
}

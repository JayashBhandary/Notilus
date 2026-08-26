import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' show CupertinoSearchTextField;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/file_entry.dart';
import '../models/media_kind.dart';
import '../providers/file_ops_provider.dart';
import '../providers/media_provider.dart';
import '../services/media_archive_service.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../services/thumbnail_service.dart';
import '../services/thumbnails/sidecar_thumbnails.dart';
import '../theme.dart';
import '../utils/platform.dart';
import '../widgets/app_dialog.dart';
import '../widgets/shad_spinner.dart';
import 'preview/file_preview_screen.dart';
import 'transfer/send_to.dart';

/// A library page for one [MediaKind] — every image, video or document under
/// the user's configured folders, independent of where the file browser is.
///
/// One widget serves all three kinds: they differ only in which extensions the
/// scan allows and how the results read best (a grid of photos, a list of
/// documents), not in what the page can do.
class MediaView extends StatefulWidget {
  const MediaView({super.key, required this.kind});

  final MediaKind kind;

  @override
  State<MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<MediaView> {
  final TextEditingController _search = TextEditingController();

  /// Set while a bulk action runs. Copy and move report through the app-wide
  /// [FileOpProgressBar]; trash and compress have no progress channel, so the
  /// selection bar shows this label and the actions disable themselves.
  String? _busyLabel;

  @override
  void initState() {
    super.initState();
    _syncSearchField();
    _kickScan();
  }

  @override
  void didUpdateWidget(covariant MediaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The center pane can swap one media page for another in place, which
    // reuses this State.
    if (oldWidget.kind != widget.kind) {
      _syncSearchField();
      _kickScan();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _syncSearchField() {
    final text = context.read<MediaProvider>().state(widget.kind).query;
    if (_search.text != text) _search.text = text;
  }

  /// Scans lazily, after the first frame: `ensureScanned` notifies listeners,
  /// which is illegal during build.
  void _kickScan() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MediaProvider>().ensureScanned(widget.kind);
    });
  }

  MediaKind get _kind => widget.kind;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final media = context.watch<MediaProvider>();
    final st = media.state(_kind);

    return Container(
      color: colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            kind: _kind,
            state: st,
            rootCount: media.roots.length,
            onRefresh: () => media.rescan(_kind),
            onCancel: () => media.cancelScan(_kind),
            onEditRoots: _showRootsDialog,
          ),
          _Controls(
            kind: _kind,
            state: st,
            controller: _search,
            onQueryChanged: (v) => media.setQuery(_kind, v),
            onSortField: (f) => media.setSortField(_kind, f),
            onToggleDirection: () => media.toggleSortDirection(_kind),
            onGroupMode: (m) => media.setGroupMode(_kind, m),
            onViewMode: (m) => media.setViewMode(_kind, m),
            onToggleLabels: () => media.toggleLabels(_kind),
            onToggleSelecting: () =>
                media.setSelecting(_kind, !st.selecting),
          ),
          if (st.selecting)
            _SelectionBar(
              state: st,
              busyLabel: _busyLabel,
              onSelectAll: () => media.selectAllVisible(_kind),
              onClear: () => media.clearSelection(_kind),
              onTrash: _trashSelected,
              onCopy: () => _transferSelected(isMove: false),
              onMove: () => _transferSelected(isMove: true),
              onSend: _sendSelected,
              onCompress: _compressSelected,
              onDone: () => media.setSelecting(_kind, false),
            ),
          Expanded(child: _body(media, st)),
        ],
      ),
    );
  }

  // ── body states ──────────────────────────────────────────────────────────

  Widget _body(MediaProvider media, MediaKindState st) {
    if (!media.ready) {
      return const _Centered(child: ShadSpinner(size: 20));
    }
    if (media.roots.isEmpty) {
      return _Empty(
        icon: LucideIcons.folderSearch,
        title: 'No folders to scan',
        message: 'Add a folder and Notilus will index the '
            '${_kind.pluralNoun} inside it.',
        action: ShadButton(
          onPressed: _addRoot,
          leading: const Icon(LucideIcons.folderPlus, size: 15),
          child: const Text('Add folder'),
        ),
      );
    }
    if (st.error != null) {
      return _Empty(
        icon: LucideIcons.triangleAlert,
        title: 'Scan failed',
        message: st.error!,
        action: ShadButton.outline(
          onPressed: () => media.rescan(_kind),
          child: const Text('Try again'),
        ),
      );
    }
    if (st.scanning && st.totalCount == 0) {
      return _Empty(
        icon: LucideIcons.radar,
        title: 'Scanning…',
        message: 'Looking through '
            '${media.roots.length} folder${media.roots.length == 1 ? '' : 's'}.',
        action: ShadButton.outline(
          onPressed: () => media.cancelScan(_kind),
          child: const Text('Stop'),
        ),
      );
    }
    if (st.totalCount == 0) {
      return _Empty(
        icon: LucideIcons.fileQuestion,
        title: 'No ${_kind.pluralNoun} found',
        message: 'Nothing matching in the folders you picked.',
        action: ShadButton.outline(
          onPressed: _showRootsDialog,
          child: const Text('Change folders'),
        ),
      );
    }
    if (st.visibleCount == 0) {
      return _Empty(
        icon: LucideIcons.searchX,
        title: 'No matches',
        message: 'Nothing here is named like “${st.query.trim()}”.',
        action: ShadButton.outline(
          onPressed: () {
            _search.clear();
            context.read<MediaProvider>().setQuery(_kind, '');
          },
          child: const Text('Clear search'),
        ),
      );
    }
    return _Listing(
      kind: _kind,
      state: st,
      onOpen: _openAt,
      onToggleSelect: (path) =>
          context.read<MediaProvider>().toggleSelect(_kind, path),
    );
  }

  void _openAt(int visibleIndex) {
    final st = context.read<MediaProvider>().state(_kind);
    if (visibleIndex < 0 || visibleIndex >= st.visibleCount) return;
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, __, ___) => FilePreviewScreen(
          files: st.visible,
          initialIndex: visibleIndex,
        ),
      ),
    );
  }

  // ── roots ────────────────────────────────────────────────────────────────

  Future<void> _addRoot() async {
    final picked = await getDirectoryPath(confirmButtonText: 'Scan this folder');
    if (picked == null || !mounted) return;
    await context.read<MediaProvider>().addRoot(picked);
    if (!mounted) return;
    // Roots changed, so every kind's cache was dropped — refill this page.
    context.read<MediaProvider>().ensureScanned(_kind);
  }

  Future<void> _showRootsDialog() async {
    await showAppDialog<void>(
      context: context,
      builder: (dialogContext) => _RootsDialog(onAdd: _addRoot),
    );
  }

  // ── bulk actions ─────────────────────────────────────────────────────────

  /// Selected paths in the order they appear on screen.
  List<String> _selectedPaths() {
    final st = context.read<MediaProvider>().state(_kind);
    return [
      for (final e in st.visible)
        if (st.selected.contains(e.path)) e.path,
    ];
  }

  Future<void> _trashSelected() async {
    final paths = _selectedPaths();
    if (paths.isEmpty || _busyLabel != null) return;

    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ShadDialog.alert(
        title: const Text('Move to Trash?'),
        description: Text(
          '${_countPhrase(paths.length)} will be moved to the Trash. You can '
          'restore ${paths.length == 1 ? 'it' : 'them'} from there.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Trash ${paths.length}'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyLabel = 'Moving to Trash…');
    try {
      final outcome = await context.read<FileOpsProvider>().trash(paths);
      if (!mounted) return;
      context.read<MediaProvider>().removePaths(_kind, outcome.trashed);
      _toast(
        outcome.failed.isEmpty ? 'Moved to Trash' : 'Partly moved to Trash',
        outcome.failed.isEmpty
            ? '${_countPhrase(outcome.trashed.length)} moved.'
            : '${outcome.trashed.length} moved, '
                '${outcome.failed.length} could not be trashed.',
        destructive: outcome.failed.isNotEmpty,
      );
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  Future<void> _transferSelected({required bool isMove}) async {
    final paths = _selectedPaths();
    if (paths.isEmpty || _busyLabel != null) return;

    final dest = await getDirectoryPath(
      confirmButtonText: isMove ? 'Move here' : 'Copy here',
    );
    if (dest == null || !mounted) return;

    final ops = context.read<FileOpsProvider>();
    // Progress for these two rides the app-wide FileOpProgressBar, so the
    // page only needs to disable its own buttons meanwhile.
    setState(() => _busyLabel = isMove ? 'Moving…' : 'Copying…');
    try {
      final result = isMove
          ? await ops.moveTo(paths, dest)
          : await ops.copyTo(paths, dest);
      if (!mounted) return;

      if (result.cancelled) {
        _toast(isMove ? 'Move cancelled' : 'Copy cancelled', 'Nothing moved.');
      } else if (result.failed.isEmpty) {
        // A clean move means every source is gone; drop them from the cache
        // rather than paying for a rescan. A partial move leaves the listing
        // alone — Refresh is the honest fix there.
        if (isMove) {
          context.read<MediaProvider>().removePaths(_kind, paths);
        }
        _toast(
          isMove ? 'Moved' : 'Copied',
          '${_countPhrase(paths.length)} → ${_shortPath(dest)}',
        );
      } else {
        _toast(
          isMove ? 'Move incomplete' : 'Copy incomplete',
          '${result.failed.length} of ${paths.length} failed. '
              'Refresh to see what is still there.',
          destructive: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  Future<void> _sendSelected() async {
    final paths = _selectedPaths();
    if (paths.isEmpty || _busyLabel != null) return;
    await showSendToSheet(context, paths);
  }

  Future<void> _compressSelected() async {
    final paths = _selectedPaths();
    if (paths.isEmpty || _busyLabel != null) return;

    final media = context.read<MediaProvider>();
    final dest = media.archiveDestination;
    if (dest == null) {
      _toast(
        'Nowhere to save',
        'Notilus could not find a Desktop or Documents folder to write the '
            'archive to.',
        destructive: true,
      );
      return;
    }

    setState(() => _busyLabel = 'Compressing ${paths.length}…');
    try {
      final result = await MediaArchiveService.instance.compressToZip(
        paths: paths,
        destDir: dest,
        baseName: _kind.label,
        stamp: DateTime.now(),
      );
      if (!mounted) return;
      if (!result.wroteArchive) {
        _toast(
          'Nothing to compress',
          'The selected files could not be read.',
          destructive: true,
        );
        return;
      }
      final where = _shortPath(dest);
      _toast(
        'Archive saved',
        '${_countPhrase(result.added)} zipped into '
            '${_basename(result.zipPath)} in $where'
            '${result.skipped > 0 ? ' — ${result.skipped} skipped.' : '.'}',
      );
    } catch (e) {
      if (!mounted) return;
      _toast('Compression failed', '$e', destructive: true);
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  String _countPhrase(int n) => '$n ${n == 1 ? 'file' : 'files'}';

  void _toast(String title, String message, {bool destructive = false}) {
    if (!mounted) return;
    final toast = destructive
        ? ShadToast.destructive(
            title: Text(title),
            description: Text(message),
          )
        : ShadToast(title: Text(title), description: Text(message));
    ShadToaster.of(context).show(toast);
  }
}

String _basename(String path) {
  final parts = path.split(Platform.pathSeparator);
  return parts.isEmpty ? path : parts.last;
}

/// Last two path segments — enough to recognise a folder without a full path
/// blowing out a toast or a button label.
String _shortPath(String path) {
  final parts = path
      .split(Platform.pathSeparator)
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.length <= 2) return path;
  return '…${Platform.pathSeparator}${parts[parts.length - 2]}'
      '${Platform.pathSeparator}${parts.last}';
}

/// Glyph for a kind, used by the page header and the sidebar.
IconData iconForMediaKind(MediaKind kind) {
  switch (kind) {
    case MediaKind.images:
      return LucideIcons.image;
    case MediaKind.videos:
      return LucideIcons.film;
    case MediaKind.documents:
      return LucideIcons.fileText;
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Header — title, count, scan state, roots.
// ──────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.kind,
    required this.state,
    required this.rootCount,
    required this.onRefresh,
    required this.onCancel,
    required this.onEditRoots,
  });

  final MediaKind kind;
  final MediaKindState state;
  final int rootCount;
  final VoidCallback onRefresh;
  final VoidCallback onCancel;
  final VoidCallback onEditRoots;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;

    // While a scan streams in, the count is a moving target — say so rather
    // than showing a number that jumps on every rebuild.
    final subtitle = state.scanning
        ? 'Scanning — ${kind.countLabel(state.totalCount)} so far'
        : state.isFiltered
            ? '${state.visibleCount} of ${kind.countLabel(state.totalCount)}'
            : kind.countLabel(state.totalCount);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(iconForMediaKind(kind), size: 20, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kind.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: colors.foreground,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.mutedForeground,
                        ),
                      ),
                    ),
                    if (state.truncated) ...[
                      const SizedBox(width: 6),
                      const ShadBadge.outline(
                        child: Text(
                          'partial',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ShadButton.outline(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: onEditRoots,
            leading: const Icon(LucideIcons.folderCog, size: 14),
            child: Text(
              '$rootCount folder${rootCount == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 6),
          if (state.scanning)
            ShadButton.outline(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              onPressed: onCancel,
              leading: const ShadSpinner(size: 12),
              child: const Text('Stop', style: TextStyle(fontSize: 12)),
            )
          else
            ShadTooltip(
              builder: (_) => const Text(
                'Rescan',
                style: TextStyle(fontSize: 11.5),
              ),
              child: ShadIconButton.ghost(
                width: 30,
                height: 30,
                padding: EdgeInsets.zero,
                iconSize: 15,
                onPressed: onRefresh,
                icon: const Icon(LucideIcons.refreshCw),
              ),
            ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Controls — search, sort, grouping, view mode, select.
// ──────────────────────────────────────────────────────────────────────────

class _Controls extends StatelessWidget {
  const _Controls({
    required this.kind,
    required this.state,
    required this.controller,
    required this.onQueryChanged,
    required this.onSortField,
    required this.onToggleDirection,
    required this.onGroupMode,
    required this.onViewMode,
    required this.onToggleLabels,
    required this.onToggleSelecting,
  });

  final MediaKind kind;
  final MediaKindState state;
  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<MediaSortField> onSortField;
  final VoidCallback onToggleDirection;
  final ValueChanged<MediaGroupMode> onGroupMode;
  final ValueChanged<MediaViewMode> onViewMode;
  final VoidCallback onToggleLabels;
  final VoidCallback onToggleSelecting;

  static const _sortLabels = {
    MediaSortField.name: 'Name',
    MediaSortField.date: 'Date',
    MediaSortField.size: 'Size',
  };

  static const _groupLabels = {
    MediaGroupMode.all: 'All',
    MediaGroupMode.year: 'Years',
    MediaGroupMode.month: 'Months',
  };

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      // Wrap, not Row: this strip carries five controls and the center pane
      // narrows to a phone width in the compact layout.
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 210,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: CupertinoSearchTextField(
                controller: controller,
                placeholder: 'Search ${kind.pluralNoun}',
                style: TextStyle(fontSize: isMobilePlatform ? 16 : 12, color: palette.text),
                backgroundColor: palette.contentBg,
                onChanged: onQueryChanged,
                onSuffixTap: () {
                  controller.clear();
                  onQueryChanged('');
                },
              ),
            ),
          ),
          _Segmented<MediaSortField>(
            values: MediaSortField.values,
            selected: state.sortField,
            labelFor: (f) => _sortLabels[f]!,
            onChanged: onSortField,
          ),
          ShadTooltip(
            builder: (_) => Text(
              state.ascending ? 'Ascending' : 'Descending',
              style: const TextStyle(fontSize: 11.5),
            ),
            child: ShadIconButton.outline(
              width: 28,
              height: 28,
              padding: EdgeInsets.zero,
              iconSize: 14,
              onPressed: onToggleDirection,
              icon: Icon(
                state.ascending
                    ? LucideIcons.arrowUpNarrowWide
                    : LucideIcons.arrowDownWideNarrow,
              ),
            ),
          ),
          _Segmented<MediaGroupMode>(
            values: MediaGroupMode.values,
            selected: state.groupMode,
            labelFor: (m) => _groupLabels[m]!,
            onChanged: onGroupMode,
          ),
          _ViewToggle(mode: state.viewMode, onChanged: onViewMode),
          // Only offered in the grid: a list row *is* its label, so hiding
          // labels there would leave nothing behind.
          if (state.viewMode == MediaViewMode.grid)
            ShadTooltip(
              builder: (_) => Text(
                state.showLabels ? 'Hide names and dates' : 'Show names',
                style: const TextStyle(fontSize: 11.5),
              ),
              child: ShadIconButton.outline(
                width: 28,
                height: 28,
                padding: EdgeInsets.zero,
                iconSize: 14,
                onPressed: onToggleLabels,
                icon: Icon(
                  state.showLabels
                      ? LucideIcons.captions
                      : LucideIcons.captionsOff,
                ),
              ),
            ),
          ShadButton.outline(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onPressed: onToggleSelecting,
            leading: Icon(
              state.selecting
                  ? LucideIcons.circleX
                  : LucideIcons.circleCheckBig,
              size: 14,
            ),
            child: Text(
              state.selecting ? 'Cancel' : 'Select',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge-pair segmented control. [ShadBadge] is the selected look and
/// [ShadBadge.outline] the unselected one — the same pairing the System
/// Overview's metric switch uses.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.values,
    required this.selected,
    required this.labelFor,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final value in values) ...[
          if (value != values.first) const SizedBox(width: 4),
          if (value == selected)
            ShadBadge(
              onPressed: () => onChanged(value),
              child: Text(
                labelFor(value),
                style: const TextStyle(fontSize: 11),
              ),
            )
          else
            ShadBadge.outline(
              onPressed: () => onChanged(value),
              child: Text(
                labelFor(value),
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ],
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.mode, required this.onChanged});

  final MediaViewMode mode;
  final ValueChanged<MediaViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewToggleButton(
            icon: LucideIcons.layoutGrid,
            tooltip: 'Grid',
            selected: mode == MediaViewMode.grid,
            onPressed: () => onChanged(MediaViewMode.grid),
            isFirst: true,
          ),
          Container(width: 1, height: 18, color: colors.border),
          _ViewToggleButton(
            icon: LucideIcons.list,
            tooltip: 'List',
            selected: mode == MediaViewMode.list,
            onPressed: () => onChanged(MediaViewMode.list),
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _ViewToggleButton extends StatelessWidget {
  const _ViewToggleButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.isFirst = false,
    this.isLast = false,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(tooltip, style: const TextStyle(fontSize: 11.5)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 30,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? palette.sidebarSelected : null,
              borderRadius: BorderRadius.horizontal(
                left: isFirst ? const Radius.circular(5) : Radius.zero,
                right: isLast ? const Radius.circular(5) : Radius.zero,
              ),
            ),
            child: Icon(
              icon,
              size: 14,
              color: selected ? colors.foreground : colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Selection bar
// ──────────────────────────────────────────────────────────────────────────

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.state,
    required this.busyLabel,
    required this.onSelectAll,
    required this.onClear,
    required this.onTrash,
    required this.onCopy,
    required this.onMove,
    required this.onSend,
    required this.onCompress,
    required this.onDone,
  });

  final MediaKindState state;
  final String? busyLabel;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onTrash;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onSend;
  final VoidCallback onCompress;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final count = state.selected.length;
    final busy = busyLabel != null;
    final enabled = count > 0 && !busy;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colors.card,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (busy) ...[
            const ShadSpinner(size: 13),
            Text(
              busyLabel!,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
          ] else
            Text(
              count == 0 ? 'Nothing selected' : '$count selected',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
          _BarAction(
            icon: LucideIcons.listChecks,
            label: 'Select all',
            enabled: !busy,
            onPressed: onSelectAll,
          ),
          _BarAction(
            icon: LucideIcons.eraser,
            label: 'Clear',
            enabled: enabled,
            onPressed: onClear,
          ),
          _BarAction(
            icon: LucideIcons.copy,
            label: 'Copy to…',
            enabled: enabled,
            onPressed: onCopy,
          ),
          _BarAction(
            icon: LucideIcons.folderInput,
            label: 'Move to…',
            enabled: enabled,
            onPressed: onMove,
          ),
          _BarAction(
            icon: LucideIcons.send,
            label: 'Send',
            enabled: enabled,
            onPressed: onSend,
          ),
          _BarAction(
            icon: LucideIcons.fileArchive,
            label: 'Compress',
            enabled: enabled,
            onPressed: onCompress,
          ),
          _BarAction(
            icon: LucideIcons.trash2,
            label: 'Trash',
            enabled: enabled,
            destructive: true,
            onPressed: onTrash,
          ),
          _BarAction(
            icon: LucideIcons.check,
            label: 'Done',
            enabled: !busy,
            onPressed: onDone,
          ),
        ],
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadButton.outline(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      enabled: enabled,
      onPressed: enabled ? onPressed : null,
      foregroundColor: destructive ? colors.destructive : null,
      leading: Icon(icon, size: 14),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Listing
// ──────────────────────────────────────────────────────────────────────────

class _Listing extends StatelessWidget {
  const _Listing({
    required this.kind,
    required this.state,
    required this.onOpen,
    required this.onToggleSelect,
  });

  final MediaKind kind;
  final MediaKindState state;

  /// Index into `state.visible` — the preview pages across the whole filtered
  /// listing, not just the group that was tapped.
  final ValueChanged<int> onOpen;
  final ValueChanged<String> onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final grid = state.viewMode == MediaViewMode.grid;
    final slivers = <Widget>[];
    var offset = 0;

    for (final group in state.groups) {
      if (group.label != null) {
        slivers.add(
          SliverToBoxAdapter(
            child: _GroupHeader(
              label: group.label!,
              count: group.entries.length,
            ),
          ),
        );
      }
      final start = offset;
      slivers.add(
        grid
            ? _gridSliver(group.entries, start)
            : _listSliver(group.entries, start),
      );
      offset += group.entries.length;
    }

    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 20)));
    return CustomScrollView(slivers: slivers);
  }

  Widget _gridSliver(List<FileEntry> entries, int start) {
    final labelled = state.showLabels;
    return SliverPadding(
      padding: labelled
          ? const EdgeInsets.fromLTRB(12, 10, 12, 4)
          : const EdgeInsets.fromLTRB(4, 6, 4, 2),
      sliver: SliverGrid.builder(
        // Without labels the tile is nothing but the thumbnail, so it goes
        // square and the gaps close up into a photo wall.
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 176,
          mainAxisSpacing: labelled ? 10 : 4,
          crossAxisSpacing: labelled ? 10 : 4,
          childAspectRatio: labelled ? 0.82 : 1,
        ),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          return _GridTile(
            entry: entry,
            kind: kind,
            showLabels: labelled,
            selecting: state.selecting,
            selected: state.selected.contains(entry.path),
            onTap: () => state.selecting
                ? onToggleSelect(entry.path)
                : onOpen(start + i),
            onToggleSelect: () => onToggleSelect(entry.path),
          );
        },
      ),
    );
  }

  Widget _listSliver(List<FileEntry> entries, int start) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      sliver: SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          return _ListRow(
            entry: entry,
            kind: kind,
            selecting: state.selecting,
            selected: state.selected.contains(entry.path),
            onTap: () => state.selecting
                ? onToggleSelect(entry.path)
                : onOpen(start + i),
            onToggleSelect: () => onToggleSelect(entry.path),
          );
        },
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.foreground,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(fontSize: 11.5, color: palette.sidebarHeader),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: colors.border)),
        ],
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.entry,
    required this.kind,
    required this.showLabels,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onToggleSelect,
  });

  final FileEntry entry;
  final MediaKind kind;
  final bool showLabels;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // A long press is the touch-friendly way into selection mode; on desktop
      // the Select button in the toolbar does the same job.
      onLongPress: onToggleSelect,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: showLabels ? _labelled(colors) : _gallery(colors),
      ),
    );
  }

  /// Bare thumbnail. With the card gone, selection has to read off the image
  /// itself — a ring plus a tint, not a change of background.
  Widget _gallery(ShadColorScheme colors) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _Thumbnail(entry: entry, kind: kind, radius: 4),
        if (selected)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.22),
                border: Border.all(color: colors.primary, width: 2),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        if (selecting)
          Positioned(
            left: 4,
            top: 4,
            child: _SelectionDot(selected: selected),
          ),
      ],
    );
  }

  Widget _labelled(ShadColorScheme colors) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: selected ? colors.accent : null,
        border: Border.all(
          color: selected ? colors.primary : colors.border,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _Thumbnail(entry: entry, kind: kind),
                ),
                if (selecting)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: _SelectionDot(selected: selected),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: colors.foreground,
            ),
          ),
          // The two label lines used to sit flush against each other and
          // against the thumbnail, which read as one cramped block.
          const SizedBox(height: 4),
          Text(
            '${_formatDate(entry.modified)} · ${formatBytes(entry.size)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.entry,
    required this.kind,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onToggleSelect,
  });

  final FileEntry entry;
  final MediaKind kind;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onToggleSelect,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? colors.accent : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              if (selecting) ...[
                _SelectionDot(selected: selected),
                const SizedBox(width: 10),
              ],
              SizedBox(
                width: 38,
                height: 38,
                child: _Thumbnail(entry: entry, kind: kind, compact: true),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: colors.foreground,
                      ),
                    ),
                    // Same 4px as the grid tile, so a row and a card read at
                    // the same density.
                    const SizedBox(height: 4),
                    Text(
                      _parentOf(entry.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: palette.sidebarHeader,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _formatDate(entry.modified),
                style: TextStyle(
                  fontSize: 11,
                  color: colors.mutedForeground,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 62,
                child: Text(
                  formatBytes(entry.size),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionDot extends StatelessWidget {
  const _SelectionDot({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? colors.primary : colors.card.withValues(alpha: 0.9),
        border: Border.all(
          color: selected ? colors.primary : colors.border,
        ),
      ),
      child: selected
          ? Icon(LucideIcons.check, size: 12, color: colors.primaryForeground)
          : null,
    );
  }
}

/// Preview for one entry.
///
/// Images decode directly. Videos, PDFs and the office/ebook formats that
/// carry a cover go through [ThumbnailService], which caches to disk and
/// degrades to a glyph wherever the machine has no renderer for the format.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.entry,
    required this.kind,
    this.compact = false,
    this.radius,
  });

  final FileEntry entry;
  final MediaKind kind;
  final bool compact;

  /// Corner rounding. Defaults to the card radius; the gallery grid passes a
  /// tighter one so abutting tiles read as a single wall.
  final double? radius;

  static int dimFor(bool compact) => compact ? 96 : 320;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final isImage = kImageExtensions.contains(entry.extension) &&
        // SVG needs a vector renderer, not Image.file.
        entry.extension != '.svg';
    final isVideo = ThumbnailService.instance.isVideo(entry);

    // A photo on a source that keeps thumbnails beside the data goes the async
    // route: a 30 KB WebP off the drive beats decoding a 40-megapixel JPEG,
    // and it is the copy the next machine will find already there.
    final viaSidecar = isImage &&
        (SidecarThumbnails.instance.writesBesideData(entry) ||
            // Nothing in this process can decode a HEIC, so `Image.file` would
            // draw a broken-image glyph over what is usually the whole camera
            // roll. The async path renders it through the OS instead.
            ThumbnailService.instance.needsExternalDecoder(entry));
    final content = isImage && !viaSidecar
        ? Image.file(
            File(entry.path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            // Decoding at display size rather than full resolution is what
            // keeps a page of 40-megapixel photos from exhausting memory.
            cacheWidth: dimFor(compact),
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _Glyph(
              icon: LucideIcons.imageOff,
              compact: compact,
              label: null,
            ),
          )
        : _AsyncThumbnail(entry: entry, kind: kind, compact: compact);

    return Container(
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(radius ?? (compact ? 6 : 8)),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: isVideo
          ? Stack(
              fit: StackFit.expand,
              children: [
                content,
                // The badge stays whether or not a frame was extracted, so a
                // video reads as playable even when it falls back to a glyph.
                Positioned(
                  right: compact ? 2 : 5,
                  bottom: compact ? 2 : 5,
                  child: _PlayBadge(compact: compact),
                ),
              ],
            )
          : content,
    );
  }
}

/// Everything that has to be generated before it can be shown. The glyph is
/// the placeholder as well as the fallback, so a scrolling grid stays calm
/// instead of filling with spinners that resolve a moment later.
class _AsyncThumbnail extends StatefulWidget {
  const _AsyncThumbnail({
    required this.entry,
    required this.kind,
    required this.compact,
  });

  final FileEntry entry;
  final MediaKind kind;
  final bool compact;

  @override
  State<_AsyncThumbnail> createState() => _AsyncThumbnailState();
}

class _AsyncThumbnailState extends State<_AsyncThumbnail> {
  late Future<_PreviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _AsyncThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tiles are recycled as the grid scrolls and as the sort order changes.
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.compact != widget.compact) {
      _future = _load();
    }
  }

  Future<_PreviewData> _load() async {
    final service = ThumbnailService.instance;
    final entry = widget.entry;
    final dim = _Thumbnail.dimFor(widget.compact);
    final sidecars = SidecarThumbnails.instance;

    // Cheapest answer first, wherever the folder lives.
    final found = _fromHit(await sidecars.lookup(entry));
    if (found != null) return found;

    final isImage = kImageExtensions.contains(entry.extension) &&
        entry.extension != '.svg';
    if (isImage) {
      // Only reached for a folder that keeps thumbnails beside it and had none
      // for this photo. Make one and leave it there; fall back to the original
      // if the drive or bucket won't take a write.
      final made = _fromHit(await sidecars.generateFromFile(entry, entry.path));
      if (made != null) return made;
      // Nowhere to leave one. For a format the OS has to decode, a render into
      // this machine's own cache is the next best thing — and where there is
      // no such renderer, on iOS above all, the file itself still goes to the
      // image widget exactly as it always did.
      final rendered = service.needsExternalDecoder(entry)
          ? await service.imageThumbnail(entry, dim: dim)
          : null;
      return _PreviewData(image: rendered ?? File(entry.path));
    }

    if (service.isVideo(entry)) {
      return _PreviewData(image: await service.videoThumbnail(entry, dim: dim));
    }
    if (entry.extension == '.pdf') {
      return _PreviewData(image: await service.pdfThumbnail(entry, dim: dim));
    }
    if (service.hasEmbeddedPreview(entry)) {
      return _PreviewData(
        image: await service.embeddedThumbnail(entry, dim: dim),
      );
    }
    // A few lines of source text is illegible at list-row size, so the row
    // keeps its glyph and only the grid gets the miniature.
    if (service.hasTextPreview(entry) && !widget.compact) {
      return _PreviewData(text: await service.textSnippet(entry));
    }
    return const _PreviewData();
  }

  _PreviewData? _fromHit(SidecarHit? hit) {
    if (hit == null) return null;
    if (hit.file != null) return _PreviewData(image: hit.file);
    if (hit.bytes != null) return _PreviewData(bytes: hit.bytes);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;

    return FutureBuilder<_PreviewData>(
      future: _future,
      builder: (context, snap) {
        final data = snap.data;
        final image = data?.image;
        final bytes = data?.bytes;
        final text = data?.text;

        Widget child;
        if (bytes != null) {
          child = Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _Thumbnail.dimFor(widget.compact),
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _fallback(),
          );
        } else if (image != null) {
          child = Image.file(
            image,
            key: ValueKey(image.path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _Thumbnail.dimFor(widget.compact),
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _fallback(),
          );
        } else if (text != null && text.trim().isNotEmpty) {
          child = _TextMiniature(text: text);
        } else {
          child = _fallback();
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: KeyedSubtree(
            key: ValueKey(image?.path ?? (text != null ? 'text' : 'glyph')),
            child: DefaultTextStyle(
              style: TextStyle(color: colors.foreground),
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _fallback() => _Glyph(
        icon: iconForMediaKind(widget.kind),
        compact: widget.compact,
        label: widget.compact ? null : _extLabel(widget.entry.extension),
      );

  String? _extLabel(String ext) =>
      ext.isEmpty ? null : ext.substring(1).toUpperCase();
}

/// Result of one preview attempt: a cached image, a text snippet, or neither.
class _PreviewData {
  const _PreviewData({this.image, this.bytes, this.text});

  /// A thumbnail on this machine: a local sidecar, or a render in the cache.
  final File? image;

  /// A thumbnail with no local file — read out of a `.thumbs` on a share or a
  /// bucket.
  final Uint8List? bytes;

  final String? text;
}

/// Finder-style miniature of a text file's first lines.
class _TextMiniature extends StatelessWidget {
  const _TextMiniature({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      color: colors.card,
      padding: const EdgeInsets.fromLTRB(5, 5, 5, 0),
      child: ClipRect(
        child: Text(
          text,
          maxLines: 14,
          overflow: TextOverflow.fade,
          softWrap: true,
          style: TextStyle(
            fontFamily: 'Menlo',
            fontSize: 5.5,
            height: 1.2,
            color: colors.foreground,
          ),
        ),
      ),
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final size = compact ? 14.0 : 20.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.card.withValues(alpha: 0.85),
        border: Border.all(color: colors.border),
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.play,
        size: compact ? 7 : 10,
        color: colors.foreground,
      ),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.icon,
    required this.compact,
    required this.label,
  });

  final IconData icon;
  final bool compact;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: compact ? 17 : 30,
          color: colors.mutedForeground,
        ),
        if (label != null) ...[
          const SizedBox(height: 5),
          Text(
            label!,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: colors.mutedForeground,
            ),
          ),
        ],
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Roots dialog
// ──────────────────────────────────────────────────────────────────────────

class _RootsDialog extends StatelessWidget {
  const _RootsDialog({required this.onAdd});

  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final media = context.watch<MediaProvider>();

    return ShadDialog(
      title: const Text('Folders to scan'),
      description: const Text(
        'Every media page indexes these folders and everything inside them.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () async {
            await onAdd();
          },
          leading: const Icon(LucideIcons.folderPlus, size: 15),
          child: const Text('Add folder'),
        ),
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 280),
        child: media.roots.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'No folders yet.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.mutedForeground,
                  ),
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final root in media.roots)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.folder,
                            size: 14,
                            color: AppColors.of(context).folderIcon,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              root,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.foreground,
                              ),
                            ),
                          ),
                          ShadTooltip(
                            builder: (_) => const Text(
                              'Remove',
                              style: TextStyle(fontSize: 11.5),
                            ),
                            child: ShadIconButton.ghost(
                              width: 26,
                              height: 26,
                              padding: EdgeInsets.zero,
                              iconSize: 13,
                              foregroundColor: colors.mutedForeground,
                              onPressed: () => media.removeRoot(root),
                              icon: const Icon(LucideIcons.x),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Shared bits
// ──────────────────────────────────────────────────────────────────────────

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: colors.mutedForeground),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
            const SizedBox(height: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.mutedForeground,
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

String _parentOf(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i <= 0 ? path : path.substring(0, i);
}

/// Compact human date, e.g. "Jul 4, 2026".
String _formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final month = (d.month >= 1 && d.month <= 12) ? months[d.month - 1] : '?';
  return '$month ${d.day}, ${d.year}';
}

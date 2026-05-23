import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../theme.dart';
import 'desk_context_menu.dart';
import 'file_icon_grid.dart';

class FileListView extends StatelessWidget {
  const FileListView({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final isList = browser.viewMode == ViewMode.list;

    return Container(
      color: palette.contentBg,
      child: Column(
        children: [
          if (isList) _Header(palette: palette, browser: browser),
          Expanded(
            child: _BackgroundCatcher(
              onSecondaryTap: (pos) =>
                  showBackgroundContextMenu(context, browser, pos),
              child: isList
                  ? _body(browser, palette)
                  : FileIconGrid(
                      onSecondaryRowTap: (entry, pos) =>
                          showRowContextMenu(context, browser, entry, pos),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BrowserProvider browser, AppPalette palette) {
    if (browser.loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final groups = browser.groupedEntries();
    final isEmpty = groups.every((g) => g.entries.isEmpty);

    if (isEmpty) {
      if (browser.error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.exclamationmark_triangle,
                  size: 32,
                  color: palette.danger,
                ),
                const SizedBox(height: 10),
                Text(
                  browser.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.subtleText,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Center(
        child: Text(
          'This folder is empty',
          style: TextStyle(color: palette.subtleText, fontSize: 13),
        ),
      );
    }

    final flat = <_ListItem>[];
    var altIndex = 0;
    for (final g in groups) {
      if (g.label != null) {
        flat.add(_ListItem.header(g.label!));
        altIndex = 0;
      }
      for (final e in g.entries) {
        flat.add(_ListItem.row(e, alt: altIndex.isOdd));
        altIndex++;
      }
    }

    return ListView.builder(
      itemCount: flat.length,
      itemBuilder: (context, i) {
        final item = flat[i];
        if (item.isHeader) {
          return _GroupHeader(label: item.header!, palette: palette);
        }
        final selected = browser.selectedPaths.contains(item.entry!.path);
        return _FileRow(
          entry: item.entry!,
          selected: selected,
          alt: item.alt,
        );
      },
    );
  }
}

class _ListItem {
  _ListItem.row(this.entry, {this.alt = false})
      : isHeader = false,
        header = null;
  _ListItem.header(String h)
      : isHeader = true,
        header = h,
        entry = null,
        alt = false;
  final bool isHeader;
  final String? header;
  final FileEntry? entry;
  final bool alt;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.palette});
  final String label;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
          color: palette.subtleText,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.palette, required this.browser});
  final AppPalette palette;
  final BrowserProvider browser;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 26),
          _SortableHeader(
            label: 'Name',
            field: SortField.name,
            flex: 5,
            palette: palette,
            browser: browser,
          ),
          _SortableHeader(
            label: 'Date modified',
            field: SortField.modified,
            flex: 3,
            palette: palette,
            browser: browser,
          ),
          _SortableHeader(
            label: 'Size',
            field: SortField.size,
            flex: 2,
            palette: palette,
            browser: browser,
          ),
        ],
      ),
    );
  }
}

class _SortableHeader extends StatelessWidget {
  const _SortableHeader({
    required this.label,
    required this.field,
    required this.flex,
    required this.palette,
    required this.browser,
  });

  final String label;
  final SortField field;
  final int flex;
  final AppPalette palette;
  final BrowserProvider browser;

  @override
  Widget build(BuildContext context) {
    final active = browser.sortField == field;
    return Expanded(
      flex: flex,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => browser.setSort(field),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    color: active ? palette.text : palette.subtleText,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(
                  browser.sortAscending
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 10,
                  color: palette.subtleText,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BackgroundCatcher extends StatelessWidget {
  const _BackgroundCatcher({
    required this.child,
    required this.onSecondaryTap,
  });

  final Widget child;
  final ValueChanged<Offset> onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) => onSecondaryTap(d.globalPosition),
      child: child,
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.entry,
    required this.selected,
    required this.alt,
  });

  final FileEntry entry;
  final bool selected;
  final bool alt;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final browser = context.read<BrowserProvider>();
    final palette = AppColors.of(context);
    Color? bg;
    if (widget.selected) {
      bg = palette.accent.withValues(alpha: 0.18);
    } else if (_hover) {
      bg = palette.sidebarHover;
    } else if (widget.alt) {
      bg = palette.rowAlt;
    }

    final density = browser.rowDensity;
    final vPad = 5 * density;
    final iconSize = 18 * density;
    final fontSize = 13 * density;

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final additive = HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed;
          browser.toggleSelect(widget.entry, additive: additive);
        },
        onDoubleTap: () {
          if (widget.entry.isDirectory) {
            browser.navigateTo(widget.entry.path);
          }
        },
        onSecondaryTapDown: (d) {
          // Make sure the right-clicked row is selected.
          if (!widget.selected) {
            browser.toggleSelect(widget.entry, additive: false);
          }
          showRowContextMenu(context, browser, widget.entry, d.globalPosition);
        },
        child: Container(
          color: bg,
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: vPad),
          child: Row(
            children: [
              Icon(
                widget.entry.isDirectory
                    ? CupertinoIcons.folder_fill
                    : _iconFor(widget.entry.extension),
                size: iconSize,
                color: widget.entry.isDirectory
                    ? palette.folderIcon
                    : palette.subtleText,
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 5,
                child: Text(
                  widget.entry.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fontSize, color: palette.text),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  _formatDate(widget.entry.modified),
                  style: TextStyle(
                    fontSize: fontSize - 1,
                    color: palette.subtleText,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  widget.entry.isDirectory
                      ? '--'
                      : _formatSize(widget.entry.size),
                  style: TextStyle(
                    fontSize: fontSize - 1,
                    color: palette.subtleText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String ext) {
    switch (ext) {
      case '.txt':
      case '.md':
      case '.log':
        return CupertinoIcons.doc_text;
      case '.json':
      case '.yaml':
      case '.yml':
      case '.xml':
        return CupertinoIcons.doc_chart;
      case '.dart':
      case '.py':
      case '.js':
      case '.ts':
      case '.go':
      case '.rs':
        return CupertinoIcons.chevron_left_slash_chevron_right;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
        return CupertinoIcons.photo;
      case '.pdf':
        return CupertinoIcons.doc_richtext;
      default:
        return CupertinoIcons.doc;
    }
  }

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ──────────────────────────────────────────────────────────────────────
// Context menu helpers
// ──────────────────────────────────────────────────────────────────────

void showBackgroundContextMenu(
  BuildContext context,
  BrowserProvider browser,
  Offset position,
) {
  showDeskContextMenu(
    context,
    globalPosition: position,
    items: _baseMenuItems(context, browser, target: null),
  );
}

void showRowContextMenu(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
  Offset position,
) {
  showDeskContextMenu(
    context,
    globalPosition: position,
    items: _baseMenuItems(context, browser, target: entry),
  );
}

List<DeskMenuItem> _baseMenuItems(
  BuildContext context,
  BrowserProvider browser, {
  required FileEntry? target,
}) {
  return [
    DeskMenuItem(
      label: 'New Folder',
      icon: CupertinoIcons.folder_badge_plus,
      enabled: browser.currentPath.isNotEmpty,
      onTap: () => _newFolder(context, browser),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Get Info',
      icon: CupertinoIcons.info_circle,
      enabled: target != null,
      onTap: target == null ? null : () => _showInfoDialog(context, target),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Use Groups',
      checked: browser.useGroups,
      onTap: () => browser.setUseGroups(!browser.useGroups),
    ),
    DeskMenuItem(
      label: 'Sort By',
      submenu: _sortSubmenu(browser),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Show View Options',
      icon: CupertinoIcons.slider_horizontal_3,
      onTap: () => _showViewOptions(context, browser),
    ),
  ];
}

List<DeskMenuItem> _sortSubmenu(BrowserProvider browser) {
  DeskMenuItem option(String label, SortField field) {
    final active = browser.sortField == field;
    return DeskMenuItem(
      label: label,
      checked: active,
      trailing: active
          ? (browser.sortAscending
              ? CupertinoIcons.arrow_up
              : CupertinoIcons.arrow_down)
          : null,
      onTap: () => browser.setSort(field),
    );
  }

  return [
    option('Name', SortField.name),
    option('Kind', SortField.kind),
    option('Date Modified', SortField.modified),
    option('Size', SortField.size),
  ];
}

Future<void> _newFolder(BuildContext context, BrowserProvider browser) async {
  final controller = TextEditingController(text: 'untitled folder');
  final palette = AppColors.of(context);
  final name = await showCupertinoDialog<String?>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('New Folder'),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: palette.text),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  final created = await browser.createFolder(name: name);
  if (created == null && context.mounted) {
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Couldn’t create folder'),
        content: const Text(
            'Check that the destination is writable and try again.'),
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
}

void _showInfoDialog(BuildContext context, FileEntry entry) {
  final palette = AppColors.of(context);
  String two(int n) => n.toString().padLeft(2, '0');
  final dt = entry.modified;
  final modified =
      '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  String formatSize(int b) {
    if (b < 1024) return '$b bytes';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  final kind = entry.isDirectory
      ? 'Folder'
      : (entry.extension.isEmpty
          ? 'Document'
          : '${entry.extension.substring(1).toUpperCase()} file');

  showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(entry.name),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'Kind', value: kind, palette: palette),
            _InfoRow(
              label: 'Size',
              value: entry.isDirectory ? '--' : formatSize(entry.size),
              palette: palette,
            ),
            _InfoRow(label: 'Modified', value: modified, palette: palette),
            _InfoRow(
              label: 'Where',
              value: p.dirname(entry.path),
              palette: palette,
            ),
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.palette,
  });
  final String label;
  final String value;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, color: palette.subtleText),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: palette.text),
            ),
          ),
        ],
      ),
    );
  }
}

void _showViewOptions(BuildContext context, BrowserProvider browser) {
  showCupertinoDialog<void>(
    context: context,
    builder: (ctx) {
      return _ViewOptionsDialog(browser: browser);
    },
  );
}

class _ViewOptionsDialog extends StatefulWidget {
  const _ViewOptionsDialog({required this.browser});
  final BrowserProvider browser;

  @override
  State<_ViewOptionsDialog> createState() => _ViewOptionsDialogState();
}

class _ViewOptionsDialogState extends State<_ViewOptionsDialog> {
  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final b = widget.browser;
    return CupertinoAlertDialog(
      title: const Text('View Options'),
      content: Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Use Groups',
                  style: TextStyle(fontSize: 13, color: palette.text),
                ),
                const Spacer(),
                CupertinoSwitch(
                  value: b.useGroups,
                  onChanged: (v) {
                    b.setUseGroups(v);
                    setState(() {});
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Sort by',
              style: TextStyle(fontSize: 12, color: palette.subtleText),
            ),
            const SizedBox(height: 4),
            CupertinoSlidingSegmentedControl<SortField>(
              groupValue: b.sortField,
              children: const {
                SortField.name: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text('Name', style: TextStyle(fontSize: 12)),
                ),
                SortField.kind: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text('Kind', style: TextStyle(fontSize: 12)),
                ),
                SortField.modified: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text('Modified', style: TextStyle(fontSize: 12)),
                ),
                SortField.size: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text('Size', style: TextStyle(fontSize: 12)),
                ),
              },
              onValueChanged: (v) {
                if (v != null) {
                  if (b.sortField != v) b.setSort(v);
                  setState(() {});
                }
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  'Row density',
                  style: TextStyle(fontSize: 12, color: palette.subtleText),
                ),
                const Spacer(),
                Text(
                  b.rowDensity < 0.95
                      ? 'Compact'
                      : (b.rowDensity > 1.1 ? 'Spacious' : 'Default'),
                  style: TextStyle(fontSize: 12, color: palette.text),
                ),
              ],
            ),
            CupertinoSlider(
              value: b.rowDensity,
              min: 0.85,
              max: 1.3,
              divisions: 9,
              onChanged: (v) {
                b.setRowDensity(v);
                setState(() {});
              },
            ),
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

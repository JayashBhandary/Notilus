import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../providers/file_ops_provider.dart';
import '../services/native_core.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../screens/preview/file_preview_screen.dart';
import '../screens/text_editor_screen.dart';
import '../screens/transfer/send_to.dart';
import '../services/file_actions_service.dart';
import '../models/remote/remote_connection.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';
import '../services/remote/sftp_file_system.dart';
import '../services/text_document_service.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import 'desk_context_menu.dart';
import 'file_drag_drop.dart';
import 'file_icon_grid.dart';
import 'path_status_bar.dart' show pathStatusBarKey;
import 'terminal_panel.dart' show TerminalLauncher;
import 'marquee_selection.dart';

final FileActionsService _actions = FileActionsService();
bool get _isMacOS => !kIsWeb && Platform.isMacOS;
bool get _isIOS => !kIsWeb && Platform.isIOS;

// Coordinates the row-vs-background right-click menus. A single right-click can
// reach both a file row and the background catcher that wraps the list (a
// selection-change rebuild lets both fire). These let the row menu win: a row
// cancels any pending background menu for the same gesture, and the background
// menu is scheduled on a microtask so a row handler (whenever it runs) can veto
// it first.
Offset? _pendingBackgroundMenu;
DateTime? _lastRowMenuAt;

/// Opens the FilePreviewScreen for [entry], using the current folder's
/// other files as siblings for swipe / arrow-key navigation.
Future<void> openFilePreview(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  // A cloud file has no bytes on this machine yet. Everything the preview can
  // do — decode an image, page a PDF, play a video — needs a real file, so the
  // object is downloaded to the cache first and previewed from there. Its
  // neighbours are left out of that: fetching a whole folder to populate a
  // filmstrip would turn one click into a bill.
  if (VPath.isRemote(entry.path)) {
    final local = await localCopyOfEntry(context, entry);
    if (local == null || !context.mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => FilePreviewScreen(
          files: [local],
          initialIndex: 0,
          // The preview is of the downloaded copy; the editor must write back
          // to the file on the source, not to the cache.
          editEntry: entry,
        ),
      ),
    );
    return;
  }

  final siblings =
      browser.entries.where((e) => !e.isDirectory).toList(growable: false);
  final idx = siblings.indexWhere((e) => e.path == entry.path);
  if (idx < 0) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) => FilePreviewScreen(
        files: siblings,
        initialIndex: idx,
      ),
    ),
  );
}

/// Downloads a remote entry to the local cache and returns it as a local
/// [FileEntry], reporting any failure to the user. Returns the entry unchanged
/// when it is already local.
Future<FileEntry?> localCopyOfEntry(
  BuildContext context,
  FileEntry entry,
) async {
  if (!VPath.isRemote(entry.path)) return entry;
  final ops = context.read<FileOpsProvider>();
  try {
    return await ops.localEntryFor(entry);
  } catch (e) {
    if (context.mounted) {
      await _showError(context, 'Couldn\'t download "${entry.name}".\n$e');
    }
    return null;
  }
}

/// Opens [entry] in the OS default application (double-click behaviour).
/// On platforms without a default-app hook (Linux/Windows) it falls back to
/// the in-app preview so double-click still does something useful.
Future<void> openFileInDefaultApp(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  if (_isMacOS || _isIOS) {
    // Remote files are opened from their downloaded copy; edits made in the
    // other app stay local, which is why the menu says "Download a Copy"
    // rather than pretending the cloud file is being edited in place.
    final local = await localCopyOfEntry(context, entry);
    if (local == null) return;
    final ok = await _actions.openInDefaultApp(local);
    if (!ok && context.mounted) {
      await _showError(context, 'Couldn\'t open "${entry.name}".');
    }
    return;
  }
  if (!context.mounted) return;
  await openFilePreview(context, browser, entry);
}

class FileListView extends StatefulWidget {
  const FileListView({super.key});

  @override
  State<FileListView> createState() => _FileListViewState();
}

class _FileListViewState extends State<FileListView> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'FileList');
  final MarqueeController _marquee = MarqueeController();

  @override
  void dispose() {
    _focusNode.dispose();
    _marquee.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final browser = context.read<BrowserProvider>();
    if (browser.centerView != CenterView.files) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final mod = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final selected = _selectedEntries(browser);

    if (mod) {
      switch (key) {
        case LogicalKeyboardKey.keyA:
          browser.selectAll();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyC:
          if (selected.isEmpty) return KeyEventResult.ignored;
          context
              .read<FileOpsProvider>()
              .copyToClipboard([for (final e in selected) e.path]);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyX:
          if (selected.isEmpty) return KeyEventResult.ignored;
          context
              .read<FileOpsProvider>()
              .cutToClipboard([for (final e in selected) e.path]);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyV:
          pasteIntoCurrentFolder(context, browser);
          return KeyEventResult.handled;
        // Cmd/Ctrl+E opens the built-in editor on a text file.
        case LogicalKeyboardKey.keyE:
          if (selected.length != 1) return KeyEventResult.ignored;
          if (!TextDocumentService.canEdit(selected.first)) {
            return KeyEventResult.ignored;
          }
          _editEntry(context, browser, selected.first);
          return KeyEventResult.handled;
        // Cmd/Ctrl+L puts the status-bar path into edit mode — the Explorer
        // and Nautilus binding.
        case LogicalKeyboardKey.keyL:
          pathStatusBarKey.currentState?.beginEditing();
          return KeyEventResult.handled;
        // Cmd/Ctrl+H toggles dotfiles, which needs a re-listing since the
        // filter is applied natively during the directory read.
        case LogicalKeyboardKey.keyH:
          browser.setShowHidden(!browser.showHidden);
          return KeyEventResult.handled;
        // Cmd/Ctrl+Up goes to the parent folder.
        case LogicalKeyboardKey.arrowUp:
          browser.goUp();
          return KeyEventResult.handled;
      }
    }

    switch (key) {
      // Del / Backspace → Trash. With Shift, delete permanently.
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        if (selected.isEmpty) return KeyEventResult.ignored;
        confirmTrashAll(context, browser, selected, permanent: shift);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.f2:
        if (selected.length != 1) return KeyEventResult.ignored;
        _renameEntry(context, browser, selected.first);
        return KeyEventResult.handled;

      // Enter opens: folders navigate, files launch in their default app.
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (selected.length != 1) return KeyEventResult.ignored;
        final target = selected.first;
        if (target.isDirectory) {
          browser.navigateTo(target.path);
        } else {
          openFileInDefaultApp(context, browser, target);
        }
        return KeyEventResult.handled;

      case LogicalKeyboardKey.space:
        final sel = browser.primarySelection;
        if (sel == null || sel.isDirectory) return KeyEventResult.ignored;
        openFilePreview(context, browser, sel);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        _moveCursor(browser, -1, extend: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _moveCursor(browser, 1, extend: shift);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Entries backing the current selection, in display order.
  List<FileEntry> _selectedEntries(BrowserProvider browser) {
    final paths = browser.selectedPaths;
    if (paths.isEmpty) return const [];
    return [
      for (final e in browser.entries)
        if (paths.contains(e.path)) e,
    ];
  }

  /// Arrow-key navigation. Without Shift this replaces the selection; with
  /// Shift it extends the range from the existing anchor.
  void _moveCursor(BrowserProvider browser, int delta, {required bool extend}) {
    final order = browser.entries;
    if (order.isEmpty) return;

    final current = browser.selectedPaths.isEmpty
        ? -1
        : order.indexWhere((e) => e.path == browser.selectedPaths.last);
    // No selection yet: Down lands on the first row, Up on the last.
    final next = current < 0
        ? (delta > 0 ? 0 : order.length - 1)
        : (current + delta).clamp(0, order.length - 1);

    if (extend) {
      browser.selectRange(order[next]);
    } else {
      browser.toggleSelect(order[next], additive: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final isList = browser.viewMode == ViewMode.list;
    // Marquee + Shift selection are desktop-only; touch layouts tap-to-open.
    _marquee.enabled = !isCompact(context);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        color: palette.contentBg,
        child: Column(
          children: [
            if (isList) _Header(palette: palette, browser: browser),
            Expanded(
              child: _BackgroundCatcher(
                onTap: () {
                  _focusNode.requestFocus();
                  // Clicking empty space clears the selection (Finder-style).
                  if (_marquee.enabled) browser.clearSelection();
                },
                onSecondaryTap: (pos) =>
                    _requestBackgroundContextMenu(context, browser, pos),
                child: Provider<MarqueeController>.value(
                  value: _marquee,
                  child: MarqueeSelectionLayer(
                    controller: _marquee,
                    child: isList
                        ? _body(browser, palette)
                        : FileIconGrid(
                            onSecondaryRowTap: (entry, pos) =>
                                showRowContextMenu(
                                    context, browser, entry, pos),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
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
      controller: _marquee.scroll,
      // Desktop: disable drag-to-scroll so a marquee drag doesn't fight the
      // scroll gesture; the layer scrolls via wheel + auto-scroll instead.
      physics: _marquee.enabled ? const NeverScrollableScrollPhysics() : null,
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
    final compact = isCompact(context);
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
          if (!compact)
            _SortableHeader(
              label: 'Kind',
              field: SortField.kind,
              flex: 2,
              palette: palette,
              browser: browser,
            ),
          if (!compact)
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
    required this.onTap,
    required this.onSecondaryTap,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<Offset> onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
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

class _FileRowState extends State<_FileRow>
    with MarqueeItemRegistration<_FileRow> {
  bool _hover = false;

  @override
  String get marqueePath => widget.entry.path;

  @override
  void dispose() {
    marqueeUnregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final browser = context.read<BrowserProvider>();
    final palette = AppColors.of(context);
    final compact = isCompact(context);
    marqueeRegister();
    Color? bg;
    if (widget.selected) {
      bg = palette.accent.withValues(alpha: 0.18);
    } else if (_hover) {
      bg = palette.sidebarHover;
    } else if (widget.alt) {
      bg = palette.rowAlt;
    }

    final density = browser.rowDensity;
    final vPad = (compact ? 8 : 5) * density;
    final iconSize = (compact ? 20 : 18) * density;
    final fontSize = 13 * density;

    // Rows are draggable, and folder rows also accept drops so a file can be
    // dropped straight onto a subfolder without navigating into it first.
    return wrapDragDrop(
      entry: widget.entry,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final additive = HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed;
            final range = HardwareKeyboard.instance.isShiftPressed;
            if (compact) {
              // Touch: tap opens — folders navigate, files preview.
              if (widget.entry.isDirectory) {
                browser.navigateTo(widget.entry.path);
              } else {
                openFilePreview(context, browser, widget.entry);
              }
              return;
            }
            // Desktop: select, and reclaim keyboard focus so space-bar
            // Quick Look fires after typing in (e.g.) the chat composer.
            Focus.maybeOf(context)?.requestFocus();
            if (range) {
              browser.selectRange(widget.entry);
            } else {
              browser.toggleSelect(widget.entry, additive: additive);
            }
          },
          onDoubleTap: () {
            // Desktop: double-click opens — folders navigate, files open in the
            // OS default app. (Space-bar still triggers in-app Quick Look.)
            if (widget.entry.isDirectory) {
              browser.navigateTo(widget.entry.path);
            } else {
              openFileInDefaultApp(context, browser, widget.entry);
            }
          },
          onLongPressStart: (d) {
            if (!widget.selected) {
              browser.toggleSelect(widget.entry, additive: false);
            }
            showRowContextMenu(
                context, browser, widget.entry, d.globalPosition);
          },
          onSecondaryTapDown: (d) {
            // Make sure the right-clicked row is selected.
            if (!widget.selected) {
              browser.toggleSelect(widget.entry, additive: false);
            }
            showRowContextMenu(
                context, browser, widget.entry, d.globalPosition);
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
                if (!compact)
                  Expanded(
                    flex: 2,
                    child: Text(
                      _kindLabel(widget.entry),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: fontSize - 1,
                        color: palette.subtleText,
                      ),
                    ),
                  ),
                if (!compact)
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

  /// The "Kind" cell. Mirrors `BrowserProvider._kindLabel` so the column and the
  /// group headings always read the same.
  String _kindLabel(FileEntry e) {
    if (e.isDirectory) return 'Folder';
    final ext = e.extension;
    if (ext.isEmpty) return 'Document';
    return '${ext.substring(1).toUpperCase()} file';
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

/// Requests the background (empty-space) context menu, but defers it to a
/// microtask so a file row handling the *same* right-click can veto it first
/// (rows call [showRowContextMenu], which clears the pending request). On
/// genuinely empty space no row fires, so the menu opens on the microtask.
void _requestBackgroundContextMenu(
  BuildContext context,
  BrowserProvider browser,
  Offset position,
) {
  _pendingBackgroundMenu = position;
  scheduleMicrotask(() {
    final pos = _pendingBackgroundMenu;
    _pendingBackgroundMenu = null;
    if (pos == null) return; // a row claimed this gesture
    // Belt-and-suspenders: if a row menu opened moments ago (e.g. the two
    // handlers ran in different frames), don't also open the background menu.
    if (_lastRowMenuAt != null &&
        DateTime.now().difference(_lastRowMenuAt!) <
            const Duration(milliseconds: 300)) {
      return;
    }
    if (!context.mounted) return;
    showBackgroundContextMenu(context, browser, pos);
  });
}

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
  // Claim this right-click so the surrounding background catcher's pending
  // (deferred) menu is cancelled and can't also open.
  _pendingBackgroundMenu = null;
  _lastRowMenuAt = DateTime.now();
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
  final fileItems = <DeskMenuItem>[];
  if (target != null) {
    final isDir = target.isDirectory;
    // A cloud item can't answer everything a local one can: there is no file
    // for another app to open, nothing for the P2P sender to read, and the
    // Rust quick actions work on real paths. Those rows are replaced with the
    // ones that *do* make sense over a network, rather than left in place to
    // fail when clicked.
    final isRemote = VPath.isRemote(target.path);
    fileItems.addAll([
      DeskMenuItem(
        label: 'Open',
        icon: LucideIcons.externalLink,
        onTap: () {
          if (isDir) {
            browser.navigateTo(target.path);
          } else {
            openFilePreview(context, browser, target);
          }
        },
      ),
      if (TextDocumentService.canEdit(target))
        DeskMenuItem(
          label: 'Edit',
          icon: LucideIcons.pencil,
          onTap: () => _editEntry(context, browser, target),
        ),
      if (!isDir && !isRemote)
        DeskMenuItem(
          label: _isIOS ? 'Share…' : 'Open With',
          icon: LucideIcons.share2,
          submenu: _isIOS ? null : _openWithSubmenu(context, target),
          onTap: _isIOS ? () async => _actions.openWithChooser(target) : null,
        ),
      if (!isDir && !isRemote)
        DeskMenuItem(
          label: 'Send to…',
          icon: LucideIcons.send,
          onTap: () => showSendToSheet(context, _sendPaths(browser, target)),
        ),
      DeskMenuItem.divider(),
      if (isRemote)
        DeskMenuItem(
          label: 'Cloud Actions',
          icon: LucideIcons.cloud,
          submenu: _remoteActionsSubmenu(context, browser, target),
        )
      else
        DeskMenuItem(
          label: 'Quick Actions',
          icon: LucideIcons.zap,
          submenu: _quickActionsSubmenu(context, browser, target),
        ),
      DeskMenuItem.divider(),
      DeskMenuItem(
        label: 'Get Info',
        icon: LucideIcons.info,
        onTap: () => _showInfoDialog(context, target),
      ),
      DeskMenuItem(
        label: 'Rename…',
        icon: LucideIcons.pencil,
        onTap: () => _renameEntry(context, browser, target),
      ),
      DeskMenuItem(
        label: 'Duplicate',
        icon: LucideIcons.copyPlus,
        onTap: () => _duplicateEntry(context, browser, target),
      ),
      DeskMenuItem.divider(),
      DeskMenuItem(
        label: _selectionLabel(browser, target, 'Copy'),
        icon: LucideIcons.copy,
        onTap: () => context
            .read<FileOpsProvider>()
            .copyToClipboard(_targetPaths(browser, target)),
      ),
      DeskMenuItem(
        label: _selectionLabel(browser, target, 'Cut'),
        icon: LucideIcons.scissors,
        onTap: () => context
            .read<FileOpsProvider>()
            .cutToClipboard(_targetPaths(browser, target)),
      ),
      DeskMenuItem(
        label: 'Copy Path',
        icon: LucideIcons.clipboard,
        onTap: () async {
          await _actions.copyPath(target);
        },
      ),
      DeskMenuItem(
        label: _isIOS || isRemote ? 'Open Parent Folder' : 'Reveal in Finder',
        icon: LucideIcons.folderOpen,
        onTap: () => _revealEntry(context, browser, target),
      ),
      DeskMenuItem.divider(),
      DeskMenuItem(
        label: _isMacOS ? 'Move to Trash' : 'Delete',
        icon: LucideIcons.trash,
        onTap: () => _confirmTrash(context, browser, target),
      ),
      DeskMenuItem.divider(),
    ]);
  }
  final ops = context.read<FileOpsProvider>();
  final pending = ops.clipboard;
  return [
    ...fileItems,
    DeskMenuItem(
      label: pending == null || pending.isEmpty
          ? 'Paste'
          : 'Paste ${pending.paths.length} Item'
              '${pending.paths.length == 1 ? '' : 's'}',
      icon: LucideIcons.clipboardPaste,
      enabled: ops.hasClipboard && browser.currentPath.isNotEmpty,
      onTap: () => pasteIntoCurrentFolder(context, browser),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'New Folder',
      icon: LucideIcons.folderPlus,
      enabled: browser.currentPath.isNotEmpty,
      onTap: () => _newFolder(context, browser),
    ),
    DeskMenuItem(
      label: 'New File',
      icon: LucideIcons.filePlus,
      enabled: browser.currentPath.isNotEmpty,
      onTap: () => _newFile(context, browser),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'View',
      icon: LucideIcons.layoutGrid,
      submenu: _viewSubmenu(context, browser),
    ),
  ];
}

/// Everything that changes how the folder is *displayed*, in one submenu.
///
/// These four used to sit loose at the bottom of the root menu, where they
/// outnumbered the actions above them: a right-click on a file offered more
/// ways to re-sort the window than to do anything to the file. Nesting them
/// keeps the root menu about the item under the cursor, and puts the display
/// toggles one predictable hop away — the arrangement Finder and Explorer both
/// settled on.
List<DeskMenuItem> _viewSubmenu(BuildContext context, BrowserProvider browser) {
  return [
    DeskMenuItem(
      label: 'as Icons',
      checked: browser.viewMode == ViewMode.icons,
      onTap: () => browser.setViewMode(ViewMode.icons),
    ),
    DeskMenuItem(
      label: 'as List',
      checked: browser.viewMode == ViewMode.list,
      onTap: () => browser.setViewMode(ViewMode.list),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Sort By',
      submenu: _sortSubmenu(browser),
    ),
    DeskMenuItem(
      label: 'Use Groups',
      checked: browser.useGroups,
      onTap: () => browser.setUseGroups(!browser.useGroups),
    ),
    DeskMenuItem(
      label: 'Show Hidden Files',
      checked: browser.showHidden,
      onTap: () => browser.setShowHidden(!browser.showHidden),
    ),
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Show View Options',
      icon: LucideIcons.settings2,
      onTap: () => _showViewOptions(context, browser),
    ),
  ];
}

/// Files to send when "Send to…" is chosen: the whole selection if [target] is
/// part of a multi-selection, otherwise just [target]. (Folders are filtered
/// out downstream by the send sheet.)
List<String> _sendPaths(BrowserProvider browser, FileEntry target) {
  final sel = browser.selectedPaths;
  if (sel.length > 1 && sel.contains(target.path)) return sel.toList();
  return [target.path];
}

/// Paths a clipboard action should act on. Right-clicking inside a
/// multi-selection acts on all of it; right-clicking elsewhere acts on the one
/// item under the cursor, matching Finder and Explorer.
List<String> _targetPaths(BrowserProvider browser, FileEntry target) =>
    _sendPaths(browser, target);

/// "Copy" vs "Copy 3 Items", depending on how much the action will affect.
String _selectionLabel(
  BrowserProvider browser,
  FileEntry target,
  String verb,
) {
  final n = _targetPaths(browser, target).length;
  return n > 1 ? '$verb $n Items' : verb;
}

List<DeskMenuItem> _openWithSubmenu(BuildContext context, FileEntry target) {
  return [
    DeskMenuItem(
      label: 'Default Application',
      icon: LucideIcons.appWindow,
      onTap: () async {
        final ok = await _actions.openInDefaultApp(target);
        if (!ok && context.mounted) _showError(context, 'Couldn\'t open.');
      },
    ),
    DeskMenuItem(
      label: 'Choose Application…',
      icon: LucideIcons.ellipsis,
      onTap: () async {
        await _actions.openWithChooser(target);
      },
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
              ? LucideIcons.arrowUp
              : LucideIcons.arrowDown)
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

// ──────────────────────────────────────────────────────────────────────
// Quick Actions
// ──────────────────────────────────────────────────────────────────────

/// Extensions the Rust core can unpack. Mirrors `archive.rs:classify`; a
/// `.tar.gz` reports `.gz` from `p.extension`, and both are in the set, so the
/// compound suffixes need no special case here.
const Set<String> _archiveExtensions = {
  '.zip',
  '.jar',
  '.tar',
  '.tgz',
  '.gz',
  '.tbz2',
  '.bz2',
};

/// Image formats the core can *write* back out. Rotating is only offered for
/// these: GIF and TIFF decode fine but can't be re-encoded without losing
/// animation or layers, so the action would be a trap.
const Set<String> _rotatableExtensions = {'.png', '.jpg', '.jpeg', '.webp'};

/// The long side, in pixels, of the "web copy" a Quick Action produces —
/// comfortably sharp on a Retina display and typically a tenth of the bytes of
/// a modern phone photo.
const int _webCopyDimension = 1600;

bool _isArchive(FileEntry e) =>
    !e.isDirectory && _archiveExtensions.contains(e.extension);

bool _isRotatable(FileEntry e) =>
    !e.isDirectory && _rotatableExtensions.contains(e.extension);

/// The Quick Actions offered for whatever is under the cursor.
///
/// The set is deliberately small and native: the four jobs a file manager gets
/// asked for constantly — zip it, unzip it, tell me how big this folder really
/// is, and fix the orientation or format of this image — each of which is a
/// byte-shovelling loop that belongs in Rust rather than on the UI isolate.
/// Everything here writes a *new* file beside the original, with the single
/// documented exception of an in-place rotate.
///
/// Per-type actions need one unambiguous subject, so a multi-selection is
/// offered only the one action that genuinely takes a list.
/// What a cloud item can do that a local one can't — and the cloud stand-ins
/// for the local Quick Actions.
List<DeskMenuItem> _remoteActionsSubmenu(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
) {
  final downloads = browser.shortcuts['Downloads'];
  // A server reached over SSH can offer a shell in the folder you're looking
  // at, which is the thing you actually want half the time you open a VPS in a
  // file manager. Object stores have no such thing, and no link either.
  final isSsh = RemoteHub.instance.connectionForPath(target.path)?.kind ==
      RemoteKind.sftp;
  return [
    if (!target.isDirectory)
      DeskMenuItem(
        label: 'Download a Copy',
        icon: LucideIcons.download,
        enabled: downloads != null && downloads.isNotEmpty,
        onTap: () => _downloadCopy(context, browser, target, downloads!),
      ),
    if (target.isDirectory && downloads != null && downloads.isNotEmpty)
      DeskMenuItem(
        label: 'Download Folder',
        icon: LucideIcons.folderDown,
        onTap: () => _downloadCopy(context, browser, target, downloads),
      ),
    DeskMenuItem.divider(),
    if (isSsh) ...[
      DeskMenuItem(
        label: 'Open SSH Session Here',
        icon: LucideIcons.terminal,
        onTap: () => _openSshSession(context, target, run: true),
      ),
      DeskMenuItem(
        label: 'Copy SSH Command',
        icon: LucideIcons.clipboard,
        onTap: () => _openSshSession(context, target, run: false),
      ),
    ] else
      DeskMenuItem(
        label: 'Copy Link',
        icon: LucideIcons.link,
        onTap: () => _copyShareLink(context, target),
      ),
    DeskMenuItem(
      label: 'Refresh Source',
      icon: LucideIcons.refreshCw,
      onTap: () {
        final id = VPath.connectionOf(target.path);
        if (id != null) RemoteHub.instance.unmount(id);
        browser.refresh();
      },
    ),
  ];
}

/// Copies a remote item into the local Downloads folder, through the same
/// transfer engine (and progress HUD) a paste would use.
Future<void> _downloadCopy(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
  String destination,
) async {
  final ops = context.read<FileOpsProvider>();
  final result = await ops.copyTo(_targetPaths(browser, target), destination);
  if (!context.mounted) return;
  if (result.failed.isNotEmpty) {
    await _showError(
      context,
      'Couldn\'t download this item:\n${result.failed.first.error}',
    );
  }
}

/// Opens the built-in text editor on [entry], wherever the file lives, and
/// refreshes the listing if it was written to.
Future<void> _editEntry(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  final saved = await openTextEditor(context, entry);
  // The editor refreshes the folder it saved into; this covers the case where
  // the user navigated elsewhere and came back.
  if (saved &&
      context.mounted &&
      browser.currentPath == VPath.dirname(entry.path)) {
    await browser.refresh();
  }
}

/// Opens the integrated terminal on the server, in the folder on screen — or
/// puts the equivalent `ssh` command on the clipboard.
///
/// The command runs in the *local* shell the app already hosts, so it uses the
/// user's own ssh client, their agent and their `~/.ssh/config`. Notilus's own
/// SFTP session is for browsing; it is not a second place to keep keys.
Future<void> _openSshSession(
  BuildContext context,
  FileEntry target, {
  required bool run,
}) async {
  final directory =
      target.isDirectory ? target.path : VPath.dirname(target.path);
  try {
    final fs = await RemoteHub.instance.fsFor(VPath.connectionOf(directory)!);
    if (fs is! SftpFileSystem) return;
    final command = fs.sshCommandFor(directory);
    if (run) {
      TerminalLauncher.run(command);
    } else {
      await Clipboard.setData(ClipboardData(text: command));
    }
  } catch (e) {
    if (context.mounted) {
      await _showError(context, 'Couldn\'t reach that server:\n$e');
    }
  }
}

/// Puts a shareable URL for a remote item on the clipboard.
///
/// The link grants nothing new: S3 hands back a presigned URL that expires in
/// an hour, Drive hands back the same link its own UI shows. Neither changes
/// who can reach the file.
Future<void> _copyShareLink(BuildContext context, FileEntry target) async {
  final ops = context.read<FileOpsProvider>();
  try {
    final link = await ops.shareLinkFor(target.path);
    if (!context.mounted) return;
    if (link == null || link.isEmpty) {
      await _showError(context, 'This source doesn\'t provide links.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
  } catch (e) {
    if (context.mounted) {
      await _showError(context, 'Couldn\'t get a link:\n$e');
    }
  }
}

List<DeskMenuItem> _quickActionsSubmenu(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
) {
  final paths = _targetPaths(browser, target);
  final items = <DeskMenuItem>[
    DeskMenuItem(
      label: paths.length > 1 ? 'Compress ${paths.length} Items' : 'Compress',
      icon: LucideIcons.fileArchive,
      onTap: () => _compressTargets(context, browser, target),
    ),
  ];
  if (paths.length > 1) return items;

  if (target.isDirectory) {
    return [
      ...items,
      DeskMenuItem.divider(),
      DeskMenuItem(
        label: 'Calculate Folder Size',
        icon: LucideIcons.calculator,
        onTap: () => _showFolderStats(context, target),
      ),
    ];
  }

  if (_isArchive(target)) {
    items.addAll([
      DeskMenuItem.divider(),
      DeskMenuItem(
        label: 'Extract to "${_archiveStem(target.name)}"',
        icon: LucideIcons.folderArchive,
        onTap: () =>
            _extractTarget(context, browser, target, intoSubfolder: true),
      ),
      DeskMenuItem(
        label: 'Extract Here',
        icon: LucideIcons.packageOpen,
        onTap: () =>
            _extractTarget(context, browser, target, intoSubfolder: false),
      ),
    ]);
  }

  if (target.isImage) {
    items.add(DeskMenuItem.divider());
    if (_isRotatable(target)) {
      items.addAll([
        DeskMenuItem(
          label: 'Rotate Left',
          icon: LucideIcons.rotateCcw,
          onTap: () => _transformImage(
              context, browser, target, ImageTransform.rotateLeft),
        ),
        DeskMenuItem(
          label: 'Rotate Right',
          icon: LucideIcons.rotateCw,
          onTap: () => _transformImage(
              context, browser, target, ImageTransform.rotateRight),
        ),
        DeskMenuItem(
          label: 'Flip Horizontally',
          icon: LucideIcons.flipHorizontal,
          onTap: () => _transformImage(
              context, browser, target, ImageTransform.flipHorizontal),
        ),
      ]);
    }
    items.add(
      DeskMenuItem(
        label: 'Convert To',
        icon: LucideIcons.fileImage,
        submenu: _convertSubmenu(context, browser, target),
      ),
    );
  }

  items.addAll([
    DeskMenuItem.divider(),
    DeskMenuItem(
      label: 'Copy SHA-256',
      icon: LucideIcons.hash,
      onTap: () => _copyChecksum(context, target),
    ),
  ]);
  return items;
}

List<DeskMenuItem> _convertSubmenu(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
) {
  DeskMenuItem option(String label, ImageTarget format, {int? maxDim}) =>
      DeskMenuItem(
        label: label,
        onTap: () =>
            _convertImage(context, browser, target, format, maxDim: maxDim),
      );

  return [
    option('PNG', ImageTarget.png),
    option('JPEG', ImageTarget.jpeg),
    // The core writes lossless WebP only, which is honest but not small — the
    // label says so rather than leaving the user to discover it from the size.
    option('WebP (lossless)', ImageTarget.webP),
    DeskMenuItem.divider(),
    option(
      'Web Copy ($_webCopyDimension px JPEG)',
      ImageTarget.jpeg,
      maxDim: _webCopyDimension,
    ),
  ];
}

/// The folder name an archive unpacks into. Mirrors `quick.rs:archive_stem`, so
/// the menu label matches the folder that actually appears.
String _archiveStem(String fileName) {
  final lower = fileName.toLowerCase();
  for (final suffix in const [
    '.tar.gz',
    '.tar.bz2',
    '.tgz',
    '.tbz2',
    '.zip',
    '.jar',
    '.tar',
    '.gz',
    '.bz2',
  ]) {
    if (lower.endsWith(suffix)) {
      return fileName.substring(0, fileName.length - suffix.length);
    }
  }
  return fileName;
}

/// Zips the selection into the folder it came from.
///
/// The archive is named after the item for a single target and after the
/// folder for a multi-selection — the two cases where a name needs no dialog.
/// Rust resolves collisions, so repeating the action adds "copy" rather than
/// overwriting the archive already there.
Future<void> _compressTargets(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
) async {
  final ops = context.read<FileOpsProvider>();
  final paths = _targetPaths(browser, target);
  final destDir = p.dirname(target.path);
  final name = paths.length > 1
      ? '${p.basename(destDir)} Archive'
      : (target.isDirectory
          ? target.name
          : p.basenameWithoutExtension(target.name));

  final result = await ops.compress(
    sources: paths,
    destDir: destDir,
    archiveName: name,
  );
  if (!context.mounted) return;
  await _afterQuickAction(context, browser, result, 'compress');
}

Future<void> _extractTarget(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target, {
  required bool intoSubfolder,
}) async {
  final ops = context.read<FileOpsProvider>();
  final result = await ops.extract(
    path: target.path,
    destDir: p.dirname(target.path),
    intoSubfolder: intoSubfolder,
  );
  if (!context.mounted) return;
  // "Extract Here" produces the folder the user is already looking at, so
  // selecting it would jump them out of the folder they extracted into.
  await _afterQuickAction(
    context,
    browser,
    result,
    'extract this archive',
    reveal: intoSubfolder,
  );
}

Future<void> _transformImage(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
  ImageTransform transform,
) async {
  try {
    // In place, like every other file manager's rotate: a suffixed copy per
    // click would turn "turn this the right way up" into a folder of near
    // duplicates. Rust encodes to a temp file and renames over the original
    // only on success, so a failure can't leave a truncated image behind.
    await NativeCore.instance
        .transformImage(src: target.path, transform: transform, inPlace: true);
  } catch (e) {
    if (context.mounted) await _showError(context, '$e');
    return;
  }
  await browser.refresh();
}

Future<void> _convertImage(
  BuildContext context,
  BrowserProvider browser,
  FileEntry target,
  ImageTarget format, {
  int? maxDim,
}) async {
  String produced;
  try {
    produced = await NativeCore.instance.convertImage(
      src: target.path,
      destDir: p.dirname(target.path),
      format: format,
      maxDim: maxDim,
    );
  } catch (e) {
    if (context.mounted) await _showError(context, '$e');
    return;
  }
  await browser.refresh();
  await browser.revealPath(produced);
}

/// Hashes the file and puts the digest on the clipboard.
///
/// The one Quick Action that writes nothing: it answers "is this the same file
/// I was sent?", which is otherwise a trip to a terminal.
Future<void> _copyChecksum(BuildContext context, FileEntry target) async {
  String digest;
  try {
    digest = await NativeCore.instance.hashFile(target.path);
  } catch (e) {
    if (context.mounted) await _showError(context, '$e');
    return;
  }
  await Clipboard.setData(ClipboardData(text: digest));
  if (!context.mounted) return;
  await showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('SHA-256 copied'),
      content: Padding(
        padding: const EdgeInsets.only(top: 6),
        // Plain Text, not SelectableText: this file is Cupertino-only and the
        // digest is already on the clipboard — the dialog is a confirmation,
        // not the copy mechanism.
        child: Text(
          digest,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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

/// Walks the folder and reports what it holds.
///
/// A directory's own size is the size of its entry, never its contents, so
/// this is the only honest answer to "how big is this folder?" — and the walk
/// is exactly why it belongs in Rust, behind the shared cancellable progress
/// bar.
Future<void> _showFolderStats(BuildContext context, FileEntry target) async {
  final ops = context.read<FileOpsProvider>();
  final stats = await ops.folderStats(target.path);
  if (!context.mounted) return;
  if (stats == null) {
    await _showError(context, 'Couldn\'t measure "${target.name}".');
    return;
  }
  if (stats.cancelled) return;

  final palette = AppColors.of(context);
  final files = stats.files.toInt();
  final dirs = stats.dirs.toInt();
  final unreadable = stats.unreadable.toInt();
  await showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(target.name),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(
              label: 'Size',
              value: formatBytes(stats.bytes.toInt()),
              palette: palette,
            ),
            _InfoRow(
              label: 'Files',
              value: '$files in $dirs folder${dirs == 1 ? '' : 's'}',
              palette: palette,
            ),
            if (stats.largestPath.isNotEmpty)
              _InfoRow(
                label: 'Largest',
                value: '${p.basename(stats.largestPath)} — '
                    '${formatBytes(stats.largestBytes.toInt())}',
                palette: palette,
              ),
            if (unreadable > 0)
              _InfoRow(
                label: 'Skipped',
                value: '$unreadable unreadable item'
                    '${unreadable == 1 ? '' : 's'}',
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

/// Shared tail for the Quick Actions that produce a file: report what failed,
/// refresh the folder, and select what was made so the result is visible.
Future<void> _afterQuickAction(
  BuildContext context,
  BrowserProvider browser,
  QuickResult result,
  String what, {
  bool reveal = true,
}) async {
  if (result.cancelled) {
    await browser.refresh();
    return;
  }
  if (result.failed.isNotEmpty) {
    final n = result.failed.length;
    await _showError(
      context,
      'Couldn\'t $what — $n item${n == 1 ? '' : 's'} failed:\n'
      '${result.failed.first.error}',
    );
  }
  if (!context.mounted) return;
  await browser.refresh();
  final produced = result.first;
  if (produced != null && reveal) await browser.revealPath(produced);
}

/// Creates an empty file in the current folder. Rust picks a collision-free
/// name, so repeated use yields "untitled", "untitled copy", and so on.
Future<void> _newFile(BuildContext context, BrowserProvider browser) async {
  final controller = TextEditingController(text: 'untitled.txt');
  final palette = AppColors.of(context);
  // Resolved before the dialog await, so the provider lookup can't outlive
  // the element that owns this context.
  final ops = context.read<FileOpsProvider>();
  final name = await showCupertinoDialog<String?>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('New File'),
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

  final String created;
  try {
    created = await ops.createFileIn(browser.currentPath, name);
  } catch (e) {
    if (context.mounted) await _showError(context, '$e');
    return;
  }
  await browser.refresh();

  // A new text file exists to be typed into. Opening the editor on it saves
  // the round trip of creating, finding and then opening the thing you just
  // asked for.
  if (!context.mounted || !TextDocumentService.looksEditable(name)) return;
  await _editEntry(
    context,
    browser,
    FileEntry(
      path: created,
      name: name,
      isDirectory: false,
      size: 0,
      modified: DateTime.now(),
    ),
  );
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
        content:
            const Text('Check that the destination is writable and try again.'),
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
  showShadDialog<void>(
    context: context,
    builder: (ctx) => _ViewOptionsDialog(browser: browser),
  );
}

/// The three row densities the dialog offers.
///
/// The slider this replaced had nine positions but only ever reported three
/// names, so most of a drag changed nothing the user could see. These are the
/// values the old Compact/Default/Spacious thresholds already named.
enum _Density {
  compact('Compact', 0.85),
  normal('Default', 1.0),
  spacious('Spacious', 1.2);

  const _Density(this.label, this.value);
  final String label;
  final double value;

  /// Nearest step to a stored density, so a value written by the old slider
  /// still lights up a button.
  static _Density nearest(double v) {
    var best = _Density.normal;
    for (final d in _Density.values) {
      if ((d.value - v).abs() < (best.value - v).abs()) best = d;
    }
    return best;
  }
}

/// Thumbnail sizes the icon grid offers, as a multiplier on the density-scaled
/// tile. Row density stops at 1.2 because list rows have to stay readable;
/// these go far past it, which is the point — a folder of photos or PDF pages
/// is worth looking at, not squinting at.
enum _IconSize {
  small('Small', 1.0),
  medium('Medium', 1.5),
  large('Large', 2.2),
  huge('Very Large', 3.2);

  const _IconSize(this.label, this.value);
  final String label;
  final double value;

  static _IconSize nearest(double v) {
    var best = _IconSize.small;
    for (final s in _IconSize.values) {
      if ((s.value - v).abs() < (best.value - v).abs()) best = s;
    }
    return best;
  }
}

const Map<SortField, String> _sortFieldLabels = {
  SortField.name: 'Name',
  SortField.kind: 'Kind',
  SortField.modified: 'Modified',
  SortField.size: 'Size',
};

class _ViewOptionsDialog extends StatefulWidget {
  const _ViewOptionsDialog({required this.browser});
  final BrowserProvider browser;

  @override
  State<_ViewOptionsDialog> createState() => _ViewOptionsDialogState();
}

class _ViewOptionsDialogState extends State<_ViewOptionsDialog> {
  @override
  Widget build(BuildContext context) {
    // Listens to the provider it was handed rather than reading it from
    // context: this is pushed on the root navigator, which in some hosts sits
    // *above* the MultiProvider, so context.watch is not dependable here.
    // Rebuilding off the object also means the controls reflect the real state
    // even when something outside the dialog changes it.
    return ListenableBuilder(
      listenable: widget.browser,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final b = widget.browser;
    final density = _Density.nearest(b.rowDensity);
    final iconSize = _IconSize.nearest(b.gridIconScale);

    return ShadDialog(
      title: const Text('View Options'),
      constraints: const BoxConstraints(maxWidth: 380),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Use Groups',
                    style: TextStyle(fontSize: 13, color: colors.foreground),
                  ),
                ),
                const SizedBox(width: 12),
                ShadSwitch(
                  value: b.useGroups,
                  onChanged: b.setUseGroups,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _OptionLabel('Sort by', colors: colors),
            const SizedBox(height: 6),
            // Chips in a Wrap rather than a segmented control: the four labels
            // did not fit the old dialog's width, so "Modified" rendered as
            // "Modifi". These reflow onto another line instead of clipping.
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in _sortFieldLabels.entries)
                  _ChoiceChip(
                    label: entry.value,
                    selected: b.sortField == entry.key,
                    // setSort() flips the direction when handed the field
                    // already in use, so only call it on an actual change —
                    // direction belongs to the context menu's Sort By submenu.
                    onTap: () {
                      if (b.sortField != entry.key) b.setSort(entry.key);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _OptionLabel('Row density', colors: colors),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in _Density.values)
                  _ChoiceChip(
                    label: d.label,
                    selected: density == d,
                    onTap: () => b.setRowDensity(d.value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _OptionLabel('Icon size (icon view)', colors: colors),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in _IconSize.values)
                  _ChoiceChip(
                    label: s.label,
                    selected: iconSize == s,
                    onTap: () => b.setGridIconScale(s.value),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionLabel extends StatelessWidget {
  const _OptionLabel(this.text, {required this.colors});
  final String text;
  final ShadColorScheme colors;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.foreground,
          ),
        ),
      );
}

/// Single-select chip. [ShadBadge] carries the filled/outlined states and takes
/// `onPressed` directly, so no gesture wrapper is needed.
class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    return selected
        ? ShadBadge(onPressed: onTap, child: text)
        : ShadBadge.outline(onPressed: onTap, child: text);
  }
}

// ──────────────────────────────────────────────────────────────────────
// File action helpers (rename / duplicate / reveal / trash)
// ──────────────────────────────────────────────────────────────────────

Future<void> _renameEntry(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  final controller = TextEditingController(text: entry.name);
  final palette = AppColors.of(context);
  final ops = context.read<FileOpsProvider>();
  final newName = await showCupertinoDialog<String?>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text('Rename "${entry.name}"'),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: palette.text),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(ctx).pop(null),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
  if (newName == null || newName.isEmpty || newName == entry.name) return;
  try {
    await ops.renameEntry(entry.path, newName);
  } catch (e) {
    if (context.mounted) await _showError(context, 'Couldn\'t rename: $e');
    return;
  }
  await browser.refresh();
}

Future<void> _duplicateEntry(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  final result = await context
      .read<FileOpsProvider>()
      .copyTo([entry.path], VPath.dirname(entry.path));
  if (result.failed.isNotEmpty && context.mounted) {
    await _showError(
      context,
      'Couldn\'t duplicate this item: ${result.failed.first.error}',
    );
    return;
  }
  await browser.refresh();
}

Future<void> _revealEntry(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) async {
  // A cloud item has no Finder entry to reveal; going to its folder inside
  // Notilus is the equivalent move.
  if (_isMacOS && !VPath.isRemote(entry.path)) {
    await _actions.revealInOs(entry);
    return;
  }
  final parent = VPath.dirname(entry.path);
  await browser.navigateTo(parent);
}

Future<void> _confirmTrash(
  BuildContext context,
  BrowserProvider browser,
  FileEntry entry,
) =>
    confirmTrashAll(context, browser, [entry]);

/// Confirms, then moves [entries] to the recycle bin — or deletes them outright
/// when [permanent] is set (Shift+Delete).
///
/// Trashing goes through the Rust core, which uses the real platform recycle
/// bin on all three desktops. The previous Dart path only did so on macOS and
/// hard-deleted on Windows and Linux.
Future<void> confirmTrashAll(
  BuildContext context,
  BrowserProvider browser,
  List<FileEntry> entries, {
  bool permanent = false,
}) async {
  if (entries.isEmpty) return;

  // Resolved before the dialog await, so the provider lookup can't outlive
  // the element that owns this context.
  final ops = context.read<FileOpsProvider>();
  final what = entries.length == 1
      ? '"${entries.first.name}"'
      : '${entries.length} items';
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(permanent ? 'Delete permanently?' : 'Move to Trash?'),
      content: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          permanent
              ? '$what will be deleted immediately. This cannot be undone.'
              : '$what will be moved to the Trash.',
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(permanent ? 'Delete' : 'Move to Trash'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  final paths = [for (final e in entries) e.path];
  final outcome =
      permanent ? await ops.deleteForever(paths) : await ops.trash(paths);

  if (!context.mounted) return;
  if (outcome.failed.isNotEmpty) {
    final n = outcome.failed.length;
    await _showError(
      context,
      '$n item${n == 1 ? '' : 's'} couldn\'t be removed:\n'
      '${outcome.failed.first.error}',
    );
  }
  await browser.refresh();
}

/// Pastes the clipboard into the folder currently on screen.
Future<void> pasteIntoCurrentFolder(
  BuildContext context,
  BrowserProvider browser,
) async {
  final ops = context.read<FileOpsProvider>();
  if (!ops.hasClipboard || browser.currentPath.isEmpty) return;

  final result = await ops.paste(browser.currentPath);
  if (!context.mounted) return;

  if (result.failed.isNotEmpty) {
    await _showError(
      context,
      'Couldn\'t paste ${result.failed.length} item'
      '${result.failed.length == 1 ? '' : 's'}:\n${result.failed.first.error}',
    );
  }
  await browser.refresh();
}

Future<void> _showError(BuildContext context, String message) async {
  await showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Couldn\'t complete action'),
      content: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(message),
      ),
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

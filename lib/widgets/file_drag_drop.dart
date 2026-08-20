import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../models/file_entry.dart';
import '../providers/browser_provider.dart';
import '../providers/file_ops_provider.dart';
import '../services/remote/remote_path.dart';
import '../theme.dart';

/// Drag and drop for files, both inside the app and to/from the OS.
///
/// `super_drag_and_drop` is used rather than Flutter's own `Draggable` because
/// only it can hand a real file URI to the desktop — dragging out to Finder or
/// Explorer needs a platform drag session, not an in-app one.
///
/// Modifier semantics follow the platform: a plain drag **moves**, and holding
/// Option (macOS) or Ctrl (Windows/Linux) **copies**. Both go through
/// [FileOpsProvider], so they get the same progress bar, cancellation and
/// collision handling as a paste.

/// True when the copy modifier is held. Read at drop time, not drag start —
/// the user can change their mind mid-drag, which is what the modifier is for.
bool _copyModifierHeld() {
  final keys = HardwareKeyboard.instance;
  return Platform.isMacOS ? keys.isAltPressed : keys.isControlPressed;
}

/// Makes an item draggable, and — for folders — also a drop target.
///
/// Folders are both: a folder can be dragged elsewhere, and other things can
/// be dropped onto it.
Widget wrapDragDrop({required FileEntry entry, required Widget child}) {
  final draggable = DraggableFileItem(entry: entry, child: child);
  if (!entry.isDirectory) return draggable;
  return FolderDropTarget(folder: entry, child: draggable);
}

/// Wraps a file row or icon so it can be dragged.
///
/// Dragging an item that is part of the current selection drags the whole
/// selection; dragging anything else drags just that item, matching Finder.
class DraggableFileItem extends StatelessWidget {
  const DraggableFileItem({
    super.key,
    required this.entry,
    required this.child,
  });

  final FileEntry entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragItemWidget(
      allowedOperations: () => [
        DropOperation.copy,
        DropOperation.move,
      ],
      dragItemProvider: (request) async {
        final browser = context.read<BrowserProvider>();
        final paths = _dragPaths(browser, entry);

        final item = DragItem(
          // Carried so an in-app drop knows what moved without going through
          // the OS clipboard formats.
          localData: {'paths': paths},
          suggestedName: entry.name,
        );
        for (final path in paths) {
          if (VPath.isRemote(path)) {
            // There is no file on disk to hand the OS. The virtual path goes
            // out as text — which is what a drop into an editor or a terminal
            // wants anyway — while the localData above keeps drops *inside*
            // Notilus working normally, including onto a local folder, where
            // they become a download.
            item.add(Formats.plainText(path));
          } else {
            // A real file URI is what makes the drop land in Finder/Explorer.
            item.add(Formats.fileUri(Uri.file(path)));
          }
        }
        return item;
      },
      child: DraggableWidget(child: child),
    );
  }
}

/// Paths a drag should carry: the whole selection when [entry] is inside it,
/// otherwise just [entry].
List<String> _dragPaths(BrowserProvider browser, FileEntry entry) {
  final sel = browser.selectedPaths;
  if (sel.length > 1 && sel.contains(entry.path)) return sel.toList();
  return [entry.path];
}

/// A folder row that accepts a drop, moving or copying into that folder.
class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({
    super.key,
    required this.folder,
    required this.child,
  });

  final FileEntry folder;
  final Widget child;

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);

    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        final paths = _incomingPaths(event.session);
        // Refuse a drop of a folder onto itself: Rust would reject it anyway,
        // but showing "no" on hover is better than an error afterwards.
        if (paths.contains(widget.folder.path)) {
          if (_hovering) setState(() => _hovering = false);
          return DropOperation.none;
        }
        if (!_hovering) setState(() => _hovering = true);
        return _copyModifierHeld() ? DropOperation.copy : DropOperation.move;
      },
      onDropLeave: (_) => setState(() => _hovering = false),
      onPerformDrop: (event) async {
        setState(() => _hovering = false);
        await handleDrop(context, event, widget.folder.path);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _hovering ? palette.accent.withValues(alpha: 0.22) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: widget.child,
      ),
    );
  }
}

/// The folder listing's background, accepting drops into the current folder.
///
/// This is what makes dragging in from Finder work: the drop doesn't have to
/// land on a specific row.
class CurrentFolderDropTarget extends StatefulWidget {
  const CurrentFolderDropTarget({super.key, required this.child});

  final Widget child;

  @override
  State<CurrentFolderDropTarget> createState() =>
      _CurrentFolderDropTargetState();
}

class _CurrentFolderDropTargetState extends State<CurrentFolderDropTarget> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final browser = context.watch<BrowserProvider>();

    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.deferToChild,
      onDropOver: (event) {
        if (browser.currentPath.isEmpty) return DropOperation.none;
        // Dropping items back into the folder they already live in is a no-op;
        // Rust skips them, but don't invite the gesture.
        final paths = _incomingPaths(event.session);
        if (paths.isNotEmpty &&
            paths.every((path) => VPath.dirname(path) == browser.currentPath)) {
          if (_hovering) setState(() => _hovering = false);
          return DropOperation.none;
        }
        if (!_hovering) setState(() => _hovering = true);
        return _copyModifierHeld() ? DropOperation.copy : DropOperation.move;
      },
      onDropLeave: (_) => setState(() => _hovering = false),
      onPerformDrop: (event) async {
        setState(() => _hovering = false);
        await handleDrop(context, event, browser.currentPath);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: palette.accent, width: 2),
                    color: palette.accent.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Paths carried by an in-flight drag, for hover-time decisions.
///
/// Only in-app drags expose this synchronously — an external drag's data is
/// readable at drop time, not on hover — so an empty list means "came from
/// outside", which is always a legal drop.
List<String> _incomingPaths(DropSession session) {
  for (final item in session.items) {
    final local = item.localData;
    if (local is Map && local['paths'] is List) {
      return List<String>.from(local['paths'] as List);
    }
  }
  return const [];
}

/// Resolves the dropped items to paths and runs the move or copy.
///
/// Exposed so the row and background targets share one implementation.
Future<void> handleDrop(
  BuildContext context,
  PerformDropEvent event,
  String destDir,
) async {
  if (destDir.isEmpty) return;
  final isCopy = _copyModifierHeld();
  final ops = context.read<FileOpsProvider>();
  final browser = context.read<BrowserProvider>();

  var paths = _incomingPaths(event.session);
  if (paths.isEmpty) {
    paths = await _readExternalPaths(event);
  }
  // Drop onto a folder that is itself being dragged, or into the folder the
  // items already occupy — nothing to do.
  paths = paths
      .where((path) => path != destDir && VPath.dirname(path) != destDir)
      .toList();
  if (paths.isEmpty) return;

  final result =
      isCopy ? await ops.copyTo(paths, destDir) : await ops.moveTo(paths, destDir);

  if (!context.mounted) return;
  if (result.failed.isNotEmpty) {
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(isCopy ? 'Couldn\'t copy' : 'Couldn\'t move'),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(result.failed.first.error),
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
  await browser.refresh();
}

/// Reads file paths out of a drag that came from outside the app.
Future<List<String>> _readExternalPaths(PerformDropEvent event) async {
  final paths = <String>[];
  for (final item in event.session.items) {
    final reader = item.dataReader;
    if (reader == null) continue;
    if (!reader.canProvide(Formats.fileUri)) continue;

    // getValue is callback-based; bridge it to a future so the drops can be
    // gathered in order.
    final completer = Completer<Uri?>();
    reader.getValue<Uri>(
      Formats.fileUri,
      completer.complete,
      onError: (_) => completer.complete(null),
    );
    final uri = await completer.future;
    if (uri != null && uri.isScheme('file')) {
      paths.add(uri.toFilePath());
    }
  }
  return paths;
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../providers/file_ops_provider.dart';
import '../widgets/file_list_view.dart';
import '../widgets/path_status_bar.dart' show pathStatusBarKey;
import '../widgets/search_bar.dart' show folderSearchKey;
import 'app_command.dart';
import 'key_combo.dart';

/// Every user-invokable action in the app, declared once.
///
/// This list is the single source of truth for three consumers, which is the
/// point: the key handlers dispatch from it, the command palette lists it, and
/// the shortcuts dialog documents it. A binding can't drift out of sync with
/// its own documentation because there is only one copy of it.
///
/// Ordering is the palette's default ordering, so the most-reached-for entries
/// come first.
final List<AppCommand> appCommands = <AppCommand>[
  // ── App ────────────────────────────────────────────────────────────────
  AppCommand(
    id: 'app.palette',
    title: 'Command Palette',
    category: 'App',
    scope: CommandScope.global,
    icon: CupertinoIcons.search,
    combo: const KeyCombo(LogicalKeyboardKey.keyK, primary: true),
    safeWhileTyping: true,
    // Already-open is handled by the palette route itself, which closes on Esc.
    inPalette: false,
    run: (env) => env.host!.openPalette(),
  ),
  AppCommand(
    id: 'app.shortcuts',
    title: 'Keyboard Shortcuts',
    category: 'App',
    scope: CommandScope.global,
    icon: CupertinoIcons.keyboard,
    combo: const KeyCombo(LogicalKeyboardKey.slash, primary: true),
    safeWhileTyping: true,
    run: (env) => env.host!.openShortcuts(),
  ),
  AppCommand(
    id: 'app.terminal',
    title: 'Toggle Terminal',
    category: 'App',
    scope: CommandScope.global,
    icon: CupertinoIcons.chevron_left_slash_chevron_right,
    combo: const KeyCombo(LogicalKeyboardKey.keyJ, primary: true),
    safeWhileTyping: true,
    run: (env) => env.host!.toggleTerminal(),
  ),
  AppCommand(
    id: 'app.settings',
    title: 'Settings',
    category: 'App',
    scope: CommandScope.global,
    icon: CupertinoIcons.settings,
    combo: const KeyCombo(LogicalKeyboardKey.comma, primary: true),
    safeWhileTyping: true,
    run: (env) => env.host!.openSettings(),
  ),

  // ── Navigation ─────────────────────────────────────────────────────────
  // Deliberately not safe-while-typing: in a text field Cmd+Up means "jump to
  // the start" and Cmd+[/] mean outdent/indent, so these yield to the field and
  // only act when the listing has focus.
  AppCommand(
    id: 'nav.back',
    title: 'Back',
    category: 'Navigation',
    scope: CommandScope.global,
    icon: CupertinoIcons.chevron_left,
    combo: const KeyCombo(LogicalKeyboardKey.bracketLeft, primary: true),
    safeWhileTyping: false,
    isEnabled: (env) => _browser(env).canGoBack,
    run: (env) => _browser(env).goBack(),
  ),
  AppCommand(
    id: 'nav.forward',
    title: 'Forward',
    category: 'Navigation',
    scope: CommandScope.global,
    icon: CupertinoIcons.chevron_right,
    combo: const KeyCombo(LogicalKeyboardKey.bracketRight, primary: true),
    safeWhileTyping: false,
    isEnabled: (env) => _browser(env).canGoForward,
    run: (env) => _browser(env).goForward(),
  ),
  AppCommand(
    id: 'nav.up',
    title: 'Enclosing Folder',
    category: 'Navigation',
    scope: CommandScope.global,
    icon: CupertinoIcons.arrow_up,
    combo: const KeyCombo(LogicalKeyboardKey.arrowUp, primary: true),
    safeWhileTyping: false,
    isEnabled: (env) => _browser(env).canGoUp,
    run: (env) => _browser(env).goUp(),
  ),
  AppCommand(
    id: 'nav.search',
    title: 'Search This Folder',
    category: 'Navigation',
    scope: CommandScope.global,
    icon: CupertinoIcons.search,
    combo: const KeyCombo(LogicalKeyboardKey.keyF, primary: true),
    safeWhileTyping: true,
    run: (_) => folderSearchKey.currentState?.focusSearch(),
  ),
  AppCommand(
    id: 'nav.editLocation',
    title: 'Edit Location',
    category: 'Navigation',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.pencil,
    combo: const KeyCombo(LogicalKeyboardKey.keyL, primary: true),
    run: (_) => pathStatusBarKey.currentState?.beginEditing(),
  ),

  // ── Go (pages and places) ──────────────────────────────────────────────
  AppCommand(
    id: 'go.overview',
    title: 'System Overview',
    category: 'Go',
    scope: CommandScope.global,
    icon: CupertinoIcons.gauge,
    run: (env) => _browser(env).showCenterView(CenterView.systemOverview),
  ),
  AppCommand(
    id: 'go.duplicates',
    title: 'Duplicate Finder',
    category: 'Go',
    scope: CommandScope.global,
    icon: CupertinoIcons.doc_on_doc,
    run: (env) => _browser(env).showCenterView(CenterView.duplicates),
  ),
  AppCommand(
    id: 'go.transfers',
    title: 'File Transfer',
    category: 'Go',
    scope: CommandScope.global,
    icon: CupertinoIcons.arrow_up_arrow_down_circle,
    run: (env) => _browser(env).showCenterView(CenterView.transfers),
  ),
  AppCommand(
    id: 'go.refreshDrives',
    title: 'Refresh Drives',
    category: 'Go',
    scope: CommandScope.global,
    icon: CupertinoIcons.arrow_clockwise,
    run: (env) => _browser(env).refreshDrives(),
  ),

  // ── View ───────────────────────────────────────────────────────────────
  AppCommand(
    id: 'view.refresh',
    title: 'Refresh',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.arrow_clockwise,
    combo: const KeyCombo(LogicalKeyboardKey.keyR, primary: true),
    safeWhileTyping: true,
    run: (env) => env.host!.refreshCenter(),
  ),
  AppCommand(
    id: 'view.icons',
    title: 'As Icons',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.square_grid_2x2,
    combo: const KeyCombo(LogicalKeyboardKey.digit1, primary: true),
    safeWhileTyping: true,
    run: (env) => _browser(env).setViewMode(ViewMode.icons),
  ),
  AppCommand(
    id: 'view.list',
    title: 'As List',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.list_bullet,
    combo: const KeyCombo(LogicalKeyboardKey.digit2, primary: true),
    safeWhileTyping: true,
    run: (env) => _browser(env).setViewMode(ViewMode.list),
  ),
  AppCommand(
    id: 'view.hidden',
    title: 'Toggle Hidden Files',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.eye,
    combo: const KeyCombo(LogicalKeyboardKey.keyH, primary: true),
    safeWhileTyping: true,
    run: (env) {
      final browser = _browser(env);
      browser.setShowHidden(!browser.showHidden);
    },
  ),
  AppCommand(
    id: 'view.options',
    title: 'View Options…',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.slider_horizontal_3,
    run: (env) => showViewOptions(env.context, _browser(env)),
  ),
  AppCommand(
    id: 'view.sidebar',
    title: 'Toggle Sidebar',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.sidebar_left,
    run: (env) => env.host!.toggleSidebar(),
  ),
  AppCommand(
    id: 'view.rightPanel',
    title: 'Toggle Right Panel',
    category: 'View',
    scope: CommandScope.global,
    icon: CupertinoIcons.sidebar_right,
    run: (env) => env.host!.toggleRightPanel(),
  ),

  // ── Files ──────────────────────────────────────────────────────────────
  AppCommand(
    id: 'file.newFolder',
    title: 'New Folder',
    category: 'Files',
    scope: CommandScope.global,
    icon: CupertinoIcons.folder_badge_plus,
    combo: const KeyCombo(LogicalKeyboardKey.keyN, primary: true),
    run: (env) => newFolderInFolder(env.context, _browser(env)),
  ),
  AppCommand(
    id: 'file.newFile',
    title: 'New File',
    category: 'Files',
    scope: CommandScope.global,
    icon: CupertinoIcons.doc_text,
    combo: const KeyCombo(
      LogicalKeyboardKey.keyN,
      primary: true,
      shift: true,
    ),
    run: (env) => newFileInFolder(env.context, _browser(env)),
  ),
  AppCommand(
    id: 'file.open',
    title: 'Open',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.arrow_up_right_square,
    combo: const KeyCombo(
      LogicalKeyboardKey.enter,
      aliases: [LogicalKeyboardKey.numpadEnter],
    ),
    keysNote: 'or Numpad Enter',
    isEnabled: (env) => _browser(env).selectedPaths.length == 1,
    run: (env) {
      final browser = _browser(env);
      final target = browser.selectedEntries.firstOrNull;
      if (target == null) return;
      if (target.isDirectory) {
        browser.navigateTo(target.path);
      } else {
        openFileInDefaultApp(env.context, browser, target);
      }
    },
  ),
  AppCommand(
    id: 'file.preview',
    title: 'Quick Look',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.eye,
    combo: const KeyCombo(LogicalKeyboardKey.space),
    isEnabled: (env) {
      final sel = _browser(env).primarySelection;
      return sel != null && !sel.isDirectory;
    },
    run: (env) {
      final browser = _browser(env);
      final sel = browser.primarySelection;
      if (sel != null) openFilePreview(env.context, browser, sel);
    },
  ),
  AppCommand(
    id: 'file.rename',
    title: 'Rename',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.pencil,
    combo: const KeyCombo(LogicalKeyboardKey.f2),
    isEnabled: (env) => _browser(env).selectedPaths.length == 1,
    run: (env) {
      final browser = _browser(env);
      final target = browser.selectedEntries.firstOrNull;
      if (target != null) renameEntry(env.context, browser, target);
    },
  ),
  AppCommand(
    id: 'file.trash',
    title: 'Move to Trash',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.delete,
    combo: const KeyCombo(
      LogicalKeyboardKey.delete,
      aliases: [LogicalKeyboardKey.backspace],
    ),
    // Cmd/Ctrl+Delete too: it's the standard Finder binding, and plenty of
    // muscle memory reaches for it.
    extraCombos: const [
      KeyCombo(
        LogicalKeyboardKey.delete,
        aliases: [LogicalKeyboardKey.backspace],
        primary: true,
      ),
    ],
    isEnabled: (env) => _browser(env).selectedPaths.isNotEmpty,
    run: (env) {
      final browser = _browser(env);
      confirmTrashAll(env.context, browser, browser.selectedEntries);
    },
  ),
  AppCommand(
    id: 'file.deletePermanently',
    title: 'Delete Permanently',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.xmark_octagon,
    combo: const KeyCombo(
      LogicalKeyboardKey.delete,
      aliases: [LogicalKeyboardKey.backspace],
      shift: true,
    ),
    isEnabled: (env) => _browser(env).selectedPaths.isNotEmpty,
    run: (env) {
      final browser = _browser(env);
      confirmTrashAll(
        env.context,
        browser,
        browser.selectedEntries,
        permanent: true,
      );
    },
  ),
  AppCommand(
    id: 'file.duplicate',
    title: 'Duplicate',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.plus_square_on_square,
    isEnabled: (env) => _browser(env).primarySelection != null,
    run: (env) {
      final browser = _browser(env);
      final target = browser.primarySelection;
      if (target != null) duplicateEntry(env.context, browser, target);
    },
  ),
  AppCommand(
    id: 'file.reveal',
    title: 'Reveal in File Manager',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.folder_open,
    isEnabled: (env) => _browser(env).primarySelection != null,
    run: (env) {
      final browser = _browser(env);
      final target = browser.primarySelection;
      if (target != null) revealEntry(env.context, browser, target);
    },
  ),
  AppCommand(
    id: 'file.info',
    title: 'Get Info',
    category: 'Files',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.info_circle,
    isEnabled: (env) => _browser(env).primarySelection != null,
    run: (env) {
      final target = _browser(env).primarySelection;
      if (target != null) showInfoDialog(env.context, target);
    },
  ),

  // ── Edit ───────────────────────────────────────────────────────────────
  AppCommand(
    id: 'edit.copy',
    title: 'Copy',
    category: 'Edit',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.doc_on_clipboard,
    combo: const KeyCombo(LogicalKeyboardKey.keyC, primary: true),
    isEnabled: (env) => _browser(env).selectedPaths.isNotEmpty,
    run: (env) => env.context
        .read<FileOpsProvider>()
        .copyToClipboard(_selectedPaths(env)),
  ),
  AppCommand(
    id: 'edit.cut',
    title: 'Cut',
    category: 'Edit',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.scissors,
    combo: const KeyCombo(LogicalKeyboardKey.keyX, primary: true),
    isEnabled: (env) => _browser(env).selectedPaths.isNotEmpty,
    run: (env) =>
        env.context.read<FileOpsProvider>().cutToClipboard(_selectedPaths(env)),
  ),
  AppCommand(
    id: 'edit.paste',
    title: 'Paste',
    category: 'Edit',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.doc_on_clipboard_fill,
    combo: const KeyCombo(LogicalKeyboardKey.keyV, primary: true),
    isEnabled: (env) => env.context.read<FileOpsProvider>().hasClipboard,
    run: (env) => pasteIntoCurrentFolder(env.context, _browser(env)),
  ),
  AppCommand(
    id: 'edit.selectAll',
    title: 'Select All',
    category: 'Edit',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.checkmark_square,
    combo: const KeyCombo(LogicalKeyboardKey.keyA, primary: true),
    run: (env) => _browser(env).selectAll(),
  ),
  AppCommand(
    id: 'edit.deselect',
    title: 'Deselect All',
    category: 'Edit',
    scope: CommandScope.fileList,
    icon: CupertinoIcons.square,
    isEnabled: (env) => _browser(env).selectedPaths.isNotEmpty,
    run: (env) => _browser(env).clearSelection(),
  ),

  // ── Selection movement (keyboard-only; noise in a palette) ─────────────
  AppCommand(
    id: 'select.up',
    title: 'Move Selection Up',
    category: 'Selection',
    scope: CommandScope.fileList,
    combo: const KeyCombo(LogicalKeyboardKey.arrowUp),
    inPalette: false,
    run: (env) => _moveCursor(_browser(env), -1, extend: false),
  ),
  AppCommand(
    id: 'select.down',
    title: 'Move Selection Down',
    category: 'Selection',
    scope: CommandScope.fileList,
    combo: const KeyCombo(LogicalKeyboardKey.arrowDown),
    inPalette: false,
    run: (env) => _moveCursor(_browser(env), 1, extend: false),
  ),
  AppCommand(
    id: 'select.extendUp',
    title: 'Extend Selection Up',
    category: 'Selection',
    scope: CommandScope.fileList,
    combo: const KeyCombo(LogicalKeyboardKey.arrowUp, shift: true),
    inPalette: false,
    run: (env) => _moveCursor(_browser(env), -1, extend: true),
  ),
  AppCommand(
    id: 'select.extendDown',
    title: 'Extend Selection Down',
    category: 'Selection',
    scope: CommandScope.fileList,
    combo: const KeyCombo(LogicalKeyboardKey.arrowDown, shift: true),
    inPalette: false,
    run: (env) => _moveCursor(_browser(env), 1, extend: true),
  ),

  // ── Preview route ──────────────────────────────────────────────────────
  AppCommand(
    id: 'preview.next',
    title: 'Next File',
    category: 'Preview',
    scope: CommandScope.preview,
    combo: const KeyCombo(
      LogicalKeyboardKey.arrowRight,
      aliases: [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.space],
    ),
    keysNote: 'or ↓ / Space',
    inPalette: false,
    run: (env) => env.preview!.next(),
  ),
  AppCommand(
    id: 'preview.previous',
    title: 'Previous File',
    category: 'Preview',
    scope: CommandScope.preview,
    combo: const KeyCombo(
      LogicalKeyboardKey.arrowLeft,
      aliases: [LogicalKeyboardKey.arrowUp],
    ),
    keysNote: 'or ↑',
    inPalette: false,
    run: (env) => env.preview!.previous(),
  ),
  AppCommand(
    id: 'preview.info',
    title: 'File Info',
    category: 'Preview',
    scope: CommandScope.preview,
    combo: const KeyCombo(LogicalKeyboardKey.keyI),
    inPalette: false,
    run: (env) => env.preview!.showInfo(),
  ),
  AppCommand(
    id: 'preview.close',
    title: 'Close Preview',
    category: 'Preview',
    scope: CommandScope.preview,
    combo: const KeyCombo(LogicalKeyboardKey.escape),
    inPalette: false,
    run: (env) => env.preview!.close(),
  ),
];

BrowserProvider _browser(CommandEnv env) => env.context.read<BrowserProvider>();

List<String> _selectedPaths(CommandEnv env) =>
    [for (final e in _browser(env).selectedEntries) e.path];

/// Arrow-key navigation. Without Shift this replaces the selection; with Shift
/// it extends the range from the existing anchor.
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

/// Runs the first command in [scope] whose shortcut matches [event].
///
/// Returns whether the event was consumed. A command that matches but is
/// currently disabled reports *not* handled, so the key falls through to
/// whatever else might want it — that's how Cmd+C keeps working in a text
/// field when the file selection happens to be empty.
/// [isTyping] is a callback rather than a bool so the check — a walk up the
/// element tree — only runs for the rare keystroke that actually matches a
/// command, not on every key down.
bool dispatchCommandKey(
  KeyEvent event,
  CommandScope scope, {
  required BuildContext context,
  HostActions? host,
  PreviewActions? preview,
  bool Function()? isTyping,
}) {
  if (event is! KeyDownEvent) return false;

  final env = CommandEnv(context: context, host: host, preview: preview);
  for (final command in appCommands) {
    if (command.scope != scope) continue;
    if (!command.combos.any((combo) => combo.matches(event))) continue;
    // A shortcut that mutates files, or that a text field defines differently,
    // must yield while the user is typing.
    if (!command.safeWhileTyping && (isTyping?.call() ?? false)) return false;
    if (!command.enabledIn(env)) return false;
    command.run(env);
    return true;
  }
  return false;
}

/// True when a text field owns the keyboard.
///
/// Deliberately not `primaryFocus.context.widget is EditableText`: the focused
/// node's own context is an internal [Focus] that `EditableText` builds, so that
/// test never matches. The EditableText sits among its ancestors instead.
bool textFieldHasFocus() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return focused.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Commands offered by the palette, in registry order.
List<AppCommand> paletteCommands() =>
    [for (final c in appCommands) if (c.inPalette) c];

/// Commands with a shortcut, grouped by [AppCommand.category] for the
/// shortcuts dialog. Category order follows first appearance in [appCommands].
Map<String, List<AppCommand>> shortcutsByCategory() {
  final grouped = <String, List<AppCommand>>{};
  for (final c in appCommands) {
    if (c.combo == null) continue;
    grouped.putIfAbsent(c.category, () => []).add(c);
  }
  return grouped;
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Navigation entries for the sidebar's favourites, surfaced in the palette so
/// places are reachable without the sidebar being visible.
List<AppCommand> placeCommands(BuildContext context) {
  final browser = context.read<BrowserProvider>();
  final places = <AppCommand>[];

  browser.shortcuts.forEach((label, path) {
    if (path == null || path.isEmpty) return;
    places.add(
      AppCommand(
        id: 'place.$path',
        title: label,
        category: 'Places',
        scope: CommandScope.global,
        icon: CupertinoIcons.folder,
        run: (env) => _browser(env).navigateTo(path),
      ),
    );
  });

  for (final drive in browser.drives) {
    places.add(
      AppCommand(
        id: 'drive.${drive.path}',
        title: drive.name.isEmpty ? drive.path : drive.name,
        category: 'Drives',
        scope: CommandScope.global,
        icon: CupertinoIcons.desktopcomputer,
        run: (env) => _browser(env).navigateTo(drive.path),
      ),
    );
  }

  return places;
}

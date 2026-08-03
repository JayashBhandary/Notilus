import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../commands/app_command.dart';
import '../commands/command_registry.dart';
import '../providers/browser_provider.dart';
import '../providers/search_provider.dart';
import '../providers/settings_provider.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import '../widgets/chat_panel.dart';
import '../widgets/command_palette.dart';
import '../widgets/file_list_view.dart';
import '../widgets/file_op_progress.dart';
import '../widgets/file_drag_drop.dart';
import '../widgets/search_bar.dart';
import '../widgets/info_panel.dart';
import '../widgets/path_status_bar.dart';
import '../widgets/shortcuts_dialog.dart';
import '../widgets/sidebar.dart';
import '../widgets/terminal_panel.dart';
import '../widgets/workflow_tab.dart';
import 'duplicate_finder_screen.dart';
import 'settings_screen.dart';
import 'system_overview_screen.dart';
import 'transfer/transfer_screen.dart';

/// Builds the widget that fills the app's central content pane for [view].
/// The System Overview view is keyed so the toolbar's refresh action can
/// reach its state.

/// The file browser pane: a search field above, and either the folder listing
/// or the search results below.
///
/// Search replaces the listing rather than filtering it, because it covers the
/// whole subtree — results come from folders that aren't on screen, so there
/// is nothing sensible to filter in place.
class _FilesPane extends StatelessWidget {
  const _FilesPane();

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final searching = context.select<SearchProvider, bool>((s) => s.isActive);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          decoration: BoxDecoration(
            color: palette.headerBg,
            border: Border(bottom: BorderSide(color: palette.divider)),
          ),
          child: FolderSearchBar(key: folderSearchKey),
        ),
        Expanded(
          child: searching
              ? const SearchResultsView()
              // Wrapping the listing (not each row) is what lets a drag from
              // Finder land anywhere in the pane, including empty space.
              : const CurrentFolderDropTarget(child: FileListView()),
        ),
      ],
    );
  }
}

Widget _centerBody(
  CenterView view,
  GlobalKey<SystemOverviewViewState> overviewKey,
) {
  switch (view) {
    case CenterView.files:
      return const _FilesPane();
    case CenterView.systemOverview:
      return SystemOverviewView(key: overviewKey);
    case CenterView.duplicates:
      return const DuplicateFinderView();
    case CenterView.transfers:
      return const TransferScreen();
  }
}

/// Human-readable title for a non-file center view (used in the header).
String _centerTitle(CenterView view) {
  switch (view) {
    case CenterView.files:
      return '';
    case CenterView.systemOverview:
      return 'System Overview';
    case CenterView.duplicates:
      return 'Duplicate Finder';
    case CenterView.transfers:
      return 'File Transfer';
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Right-pane tab (wide layout: 0=Info, 1=Chat, 2=Workflows).
  int _rightTab = 0;
  // Compact-layout main tab (0=Files, 1=Info, 2=Chat, 3=Workflows).
  int _compactTab = 0;
  // Slide-in drawer state for compact.
  bool _drawerOpen = false;
  // Integrated terminal state.
  bool _terminalOpen = false;
  double _terminalHeight = 280;
  static const double _terminalMin = 120;
  static const double _terminalMax = 600;

  // Keyed so the toolbar's refresh button can re-run the System Overview scan.
  final GlobalKey<SystemOverviewViewState> _overviewKey = GlobalKey();

  /// Host-level actions the command registry needs. Panel visibility and
  /// dialogs live here rather than in a provider, so commands reach them
  /// through this seam.
  late final HostActions _host = HostActions(
    toggleTerminal: _toggleTerminal,
    openSettings: _openSettings,
    openPalette: _openPalette,
    openShortcuts: _openShortcuts,
    toggleSidebar: () => context.read<SettingsProvider>().toggleSidebar(),
    toggleRightPanel: () =>
        context.read<SettingsProvider>().toggleRightPanel(),
    refreshCenter: _refreshCenter,
  );

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    super.dispose();
  }

  /// App-wide shortcuts, dispatched from the command registry.
  ///
  /// Registered on [HardwareKeyboard] so it runs *ahead* of focus dispatch —
  /// that's what stops the embedded terminal from swallowing Cmd+J or Cmd+K.
  /// Running first also means the two guards below matter: without them a
  /// global binding would fire over a dialog, or while the user is mid-word in
  /// a text field.
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;

    // A dialog or the preview route sitting on top owns the keyboard.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    return dispatchCommandKey(
      event,
      CommandScope.global,
      context: context,
      host: _host,
      // Inline fields — the search box, the editable path — aren't modal, so
      // the route check above can't see them.
      isTyping: textFieldHasFocus,
    );
  }

  void _openSettings() => showSettingsDialog(context);

  void _openPalette() =>
      showCommandPalette(hostContext: context, host: _host);

  void _openShortcuts() => showShortcutsDialog(context);

  /// Cmd+R refreshes whatever the centre pane is showing: System Overview
  /// re-runs its scan, anything else re-lists the folder.
  void _refreshCenter() {
    final browser = context.read<BrowserProvider>();
    if (browser.centerView == CenterView.systemOverview) {
      _overviewKey.currentState?.refresh();
    } else {
      browser.refresh();
    }
  }

  void _toggleDrawer() => setState(() => _drawerOpen = !_drawerOpen);
  void _closeDrawer() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  void _toggleTerminal() =>
      setState(() => _terminalOpen = !_terminalOpen);
  void _closeTerminal() {
    if (_terminalOpen) setState(() => _terminalOpen = false);
  }

  void _resizeTerminal(double deltaY) {
    // Drag handle is on the top edge: dragging up (negative delta) grows.
    setState(() {
      _terminalHeight =
          (_terminalHeight - deltaY).clamp(_terminalMin, _terminalMax);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = isCompactWidth(width);

    // Snap drawer shut if user resizes back to wide layout.
    if (!compact && _drawerOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _drawerOpen = false);
      });
    }

    // Publishes the host actions to the subtree so the file list's own scoped
    // shortcuts can reach them.
    return CommandHost(
      actions: _host,
      child: CupertinoPageScaffold(
        backgroundColor: palette.contentBg,
        child: compact
          ? _CompactLayout(
              tab: _compactTab,
              onTabChanged: (i) => setState(() => _compactTab = i),
              drawerOpen: _drawerOpen,
              onToggleDrawer: _toggleDrawer,
              onCloseDrawer: _closeDrawer,
              onSettings: _openSettings,
              onPalette: _openPalette,
              terminalOpen: _terminalOpen,
              terminalHeight: _terminalHeight,
              onToggleTerminal: _toggleTerminal,
              onCloseTerminal: _closeTerminal,
              onResizeTerminal: _resizeTerminal,
              overviewKey: _overviewKey,
            )
          : _WideLayout(
              rightTab: _rightTab,
              onRightTabChanged: (i) => setState(() => _rightTab = i),
              onSettings: _openSettings,
              onPalette: _openPalette,
              terminalOpen: _terminalOpen,
              terminalHeight: _terminalHeight,
              onToggleTerminal: _toggleTerminal,
              onCloseTerminal: _closeTerminal,
              onResizeTerminal: _resizeTerminal,
              overviewKey: _overviewKey,
            ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Wide (desktop / iPad-landscape) layout — fluid 3-pane.
// ──────────────────────────────────────────────────────────────────────────

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.rightTab,
    required this.onRightTabChanged,
    required this.onSettings,
    required this.onPalette,
    required this.terminalOpen,
    required this.terminalHeight,
    required this.onToggleTerminal,
    required this.onCloseTerminal,
    required this.onResizeTerminal,
    required this.overviewKey,
  });

  final int rightTab;
  final ValueChanged<int> onRightTabChanged;
  final VoidCallback onSettings;
  final VoidCallback onPalette;
  final bool terminalOpen;
  final double terminalHeight;
  final VoidCallback onToggleTerminal;
  final VoidCallback onCloseTerminal;
  final ValueChanged<double> onResizeTerminal;
  final GlobalKey<SystemOverviewViewState> overviewKey;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final settings = context.watch<SettingsProvider>();
    final width = MediaQuery.sizeOf(context).width;
    final browser = context.watch<BrowserProvider>();
    final cwd = browser.currentPath;
    final centerView = browser.centerView;

    final sidebarCollapsed = settings.sidebarCollapsed;
    final rightCollapsed = settings.rightPanelCollapsed;

    // Shrink panels gracefully on narrow desktop windows.
    final sidebarWidth = width < 1000 ? 180.0 : 210.0;
    final rightPanelWidth = width < 1100 ? 320.0 : 400.0;

    // Sidebar now extends edge-to-edge (Finder-style). The top bar lives
    // inside the main column so the sidebar can run beneath/around the
    // macOS traffic lights.
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: sidebarCollapsed
                    ? const SizedBox(height: double.infinity)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Sidebar(width: sidebarWidth),
                          _VDivider(color: palette.divider),
                        ],
                      ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _WideTopBar(
                      onSettings: onSettings,
                      onPalette: onPalette,
                      onToggleTerminal: onToggleTerminal,
                      terminalOpen: terminalOpen,
                      sidebarCollapsed: sidebarCollapsed,
                      rightPanelCollapsed: rightCollapsed,
                      onToggleSidebar: settings.toggleSidebar,
                      onToggleRightPanel: settings.toggleRightPanel,
                      centerView: centerView,
                      onRefreshOverview: () =>
                          overviewKey.currentState?.refresh(),
                    ),
                    Expanded(child: _centerBody(centerView, overviewKey)),
                    if (terminalOpen)
                      TerminalPanel(
                        cwd: cwd,
                        height: terminalHeight,
                        onResize: onResizeTerminal,
                        onClose: onCloseTerminal,
                      ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: rightCollapsed
                    ? const SizedBox(height: double.infinity)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _VDivider(color: palette.divider),
                          SizedBox(
                            width: rightPanelWidth,
                            child: Column(
                              children: [
                                _SegmentedHeader(
                                  index: rightTab,
                                  onChanged: onRightTabChanged,
                                ),
                                Expanded(
                                  child: IndexedStack(
                                    index: rightTab,
                                    children: const [
                                      InfoPanel(),
                                      ChatPanel(),
                                      WorkflowTab(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        const FileOpProgressBar(),
        PathStatusBar(key: pathStatusBarKey),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Compact (phone / iPad-portrait split-view) layout.
// Bottom tab bar with Files/Info/Chat/Workflows + slide-in sidebar drawer.
// ──────────────────────────────────────────────────────────────────────────

class _CompactLayout extends StatelessWidget {
  const _CompactLayout({
    required this.tab,
    required this.onTabChanged,
    required this.drawerOpen,
    required this.onToggleDrawer,
    required this.onCloseDrawer,
    required this.onSettings,
    required this.onPalette,
    required this.terminalOpen,
    required this.terminalHeight,
    required this.onToggleTerminal,
    required this.onCloseTerminal,
    required this.onResizeTerminal,
    required this.overviewKey,
  });

  final int tab;
  final ValueChanged<int> onTabChanged;
  final bool drawerOpen;
  final VoidCallback onToggleDrawer;
  final VoidCallback onCloseDrawer;
  final VoidCallback onSettings;
  final VoidCallback onPalette;
  final bool terminalOpen;
  final double terminalHeight;
  final VoidCallback onToggleTerminal;
  final VoidCallback onCloseTerminal;
  final ValueChanged<double> onResizeTerminal;
  final GlobalKey<SystemOverviewViewState> overviewKey;

  static const _drawerWidth = 260.0;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final browser = context.watch<BrowserProvider>();
    final cwd = browser.currentPath;
    final centerView = browser.centerView;

    return Stack(
      children: [
        SafeArea(
          bottom: false,
          child: Column(
            children: [
              _CompactTopBar(
                onMenu: onToggleDrawer,
                onSettings: onSettings,
                onPalette: onPalette,
                onToggleTerminal: onToggleTerminal,
                terminalOpen: terminalOpen,
                title: tab == 0 ? _centerTitle(centerView) : '',
              ),
              Expanded(
                child: IndexedStack(
                  index: tab,
                  children: [
                    _centerBody(centerView, overviewKey),
                    const InfoPanel(),
                    const ChatPanel(),
                    const WorkflowTab(),
                  ],
                ),
              ),
              if (terminalOpen)
                TerminalPanel(
                  cwd: cwd,
                  height: terminalHeight,
                  onResize: onResizeTerminal,
                  onClose: onCloseTerminal,
                ),
              const FileOpProgressBar(),
              PathStatusBar(key: pathStatusBarKey),
              SafeArea(
                top: false,
                child: _CompactTabBar(
                  index: tab,
                  onChanged: onTabChanged,
                ),
              ),
            ],
          ),
        ),
        // Scrim + drawer.
        IgnorePointer(
          ignoring: !drawerOpen,
          child: AnimatedOpacity(
            opacity: drawerOpen ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCloseDrawer,
              child: Container(color: const Color(0x66000000)),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          left: drawerOpen ? 0 : -_drawerWidth,
          width: _drawerWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.sidebarBg,
              border: Border(right: BorderSide(color: palette.divider)),
            ),
            child: Sidebar(
              width: _drawerWidth,
              onNavigate: onCloseDrawer,
              onFocusCenter: () => onTabChanged(0),
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Top bars
// ──────────────────────────────────────────────────────────────────────────

class _WideTopBar extends StatelessWidget {
  const _WideTopBar({
    required this.onSettings,
    required this.onPalette,
    required this.onToggleTerminal,
    required this.terminalOpen,
    required this.sidebarCollapsed,
    required this.rightPanelCollapsed,
    required this.onToggleSidebar,
    required this.onToggleRightPanel,
    required this.centerView,
    required this.onRefreshOverview,
  });
  final VoidCallback onSettings;
  final VoidCallback onPalette;
  final VoidCallback onToggleTerminal;
  final bool terminalOpen;
  final bool sidebarCollapsed;
  final bool rightPanelCollapsed;
  final VoidCallback onToggleSidebar;
  final VoidCallback onToggleRightPanel;
  final CenterView centerView;
  final VoidCallback onRefreshOverview;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);

    // When the sidebar is hidden this bar sits at the window's left edge,
    // under the macOS traffic lights — pad it clear of them.
    final leadPad = (sidebarCollapsed && Platform.isMacOS) ? 72.0 : 0.0;

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      padding: EdgeInsets.only(left: 6 + leadPad, right: 6),
      child: LayoutBuilder(
        builder: (ctx, c) {
          // Progressively shed non-essential controls as the center pane
          // narrows (both side panels open on a small window), so the row
          // never overflows. Priority, widest-first: full model pill →
          // grid/list toggle → back/forward nav. The sidebar/panel toggles,
          // terminal, connection dot and settings always stay.
          final w = c.maxWidth;
          final showFullPill = w >= 440;
          final showViewToggle = w >= 360;
          final showNav = w >= 290;
          return Row(
            children: [
              _ToolbarIconButton(
                icon: CupertinoIcons.sidebar_left,
                tooltip: sidebarCollapsed ? 'Show Sidebar' : 'Hide Sidebar',
                onPressed: onToggleSidebar,
                size: 30,
                highlighted: !sidebarCollapsed,
              ),
              const SizedBox(width: 4),
              // Middle section: file controls when browsing files, otherwise a
              // contextual page header (title + page actions).
              if (centerView == CenterView.files) ...[
                if (showNav) ...[
                  _ToolbarIconButton(
                    icon: CupertinoIcons.chevron_left,
                    tooltip: 'Back',
                    onPressed: browser.canGoBack ? browser.goBack : null,
                    size: 30,
                  ),
                  _ToolbarIconButton(
                    icon: CupertinoIcons.chevron_right,
                    tooltip: 'Forward',
                    onPressed:
                        browser.canGoForward ? browser.goForward : null,
                    size: 30,
                  ),
                  // Up sits with Back/Forward rather than on its own row —
                  // they're the same kind of control, and the path itself
                  // lives in the status bar at the bottom.
                  _ToolbarIconButton(
                    icon: CupertinoIcons.arrow_up,
                    tooltip: 'Up',
                    onPressed: browser.canGoUp ? browser.goUp : null,
                    size: 30,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: _CurrentFolderLabel(path: browser.currentPath),
                ),
                const SizedBox(width: 8),
                if (showViewToggle) ...[
                  _ViewModeToggle(browser: browser),
                  const SizedBox(width: 4),
                ],
              ] else ...[
                Expanded(
                  child: Text(
                    _centerTitle(centerView),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                ),
                if (centerView == CenterView.systemOverview) ...[
                  _ToolbarIconButton(
                    icon: CupertinoIcons.arrow_clockwise,
                    tooltip: 'Refresh',
                    onPressed: onRefreshOverview,
                    size: 30,
                  ),
                  const SizedBox(width: 4),
                ],
              ],
              // Tail group: terminal, AI model, settings, panel toggle.
              // The palette is the entry point to every command, so it gets a
              // button: a Cmd+K-only feature is one nobody finds.
              _ToolbarIconButton(
                icon: CupertinoIcons.command,
                tooltip:
                    'Command Palette (${Platform.isMacOS ? "⌘" : "Ctrl"}+K)',
                onPressed: onPalette,
                size: 30,
              ),
              const SizedBox(width: 4),
              _ToolbarIconButton(
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                tooltip:
                    'Terminal (${Platform.isMacOS ? "⌘" : "Ctrl"}+J)',
                onPressed: onToggleTerminal,
                size: 30,
                highlighted: terminalOpen,
              ),
              const SizedBox(width: 4),
              // Not wrapped in Flexible: a second flex child would split the
              // free space with the title/label Expanded and leave dead space
              // at the far right. The pill self-limits (maxWidth + ellipsis)
              // and collapses to a dot on narrow windows.
              if (showFullPill)
                _ConnectionPill(
                  connected: settings.connected,
                  model: settings.model,
                  onTap: onSettings,
                )
              else
                _ConnectionDot(
                  connected: settings.connected,
                  onTap: onSettings,
                ),
              const SizedBox(width: 4),
              _ToolbarIconButton(
                icon: CupertinoIcons.settings,
                tooltip: 'Settings',
                onPressed: onSettings,
                size: 30,
              ),
              const SizedBox(width: 4),
              _ToolbarIconButton(
                icon: CupertinoIcons.sidebar_right,
                tooltip:
                    rightPanelCollapsed ? 'Show Panel' : 'Hide Panel',
                onPressed: onToggleRightPanel,
                size: 30,
                highlighted: !rightPanelCollapsed,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CompactTopBar extends StatelessWidget {
  const _CompactTopBar({
    required this.onMenu,
    required this.onSettings,
    required this.onPalette,
    required this.onToggleTerminal,
    required this.terminalOpen,
    this.title = '',
  });
  final VoidCallback onMenu;
  final VoidCallback onSettings;
  final VoidCallback onPalette;
  final VoidCallback onToggleTerminal;
  final bool terminalOpen;

  /// When non-empty, shown in place of the current-folder label (used when a
  /// non-file page occupies the center pane).
  final String title;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _ToolbarIconButton(
            icon: CupertinoIcons.sidebar_left,
            tooltip: 'Menu',
            onPressed: onMenu,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: title.isNotEmpty
                ? Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  )
                : _CurrentFolderLabel(path: browser.currentPath),
          ),
          const SizedBox(width: 4),
          _ToolbarIconButton(
            icon: CupertinoIcons.command,
            tooltip: 'Command Palette',
            onPressed: onPalette,
          ),
          _ToolbarIconButton(
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
            tooltip: 'Terminal',
            onPressed: onToggleTerminal,
            highlighted: terminalOpen,
          ),
          _ConnectionDot(connected: settings.connected, onTap: onSettings),
          _ToolbarIconButton(
            icon: CupertinoIcons.settings,
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _CurrentFolderLabel extends StatelessWidget {
  const _CurrentFolderLabel({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final name = _displayName(path);
    return Text(
      name,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
    );
  }

  String _displayName(String path) {
    if (path.isEmpty) return '';
    if (path == '/' || path == r'\') return '/';
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.connected, required this.onTap});
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected ? palette.success : palette.danger,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Compact bottom tab bar
// ──────────────────────────────────────────────────────────────────────────

class _CompactTabBar extends StatelessWidget {
  const _CompactTabBar({required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (CupertinoIcons.folder, 'Files'),
    (CupertinoIcons.info_circle, 'Info'),
    (CupertinoIcons.bubble_left, 'Chat'),
    (CupertinoIcons.bolt, 'Flows'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: List.generate(_items.length, (i) {
            final selected = i == index;
            final item = _items[i];
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      item.$1,
                      size: 22,
                      color: selected ? palette.accent : palette.subtleText,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.$2,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? palette.accent : palette.subtleText,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Shared chrome helpers (kept private; identical to old _Divider /
// _ViewModeToggle / _ToolbarIconButton / _ConnectionPill / _SegmentedHeader).
// ──────────────────────────────────────────────────────────────────────────

class _VDivider extends StatelessWidget {
  const _VDivider({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(width: 1, color: color);
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.browser});
  final BrowserProvider browser;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _ViewModeButton(
            icon: CupertinoIcons.square_grid_2x2,
            tooltip: 'Icons',
            selected: browser.viewMode == ViewMode.icons,
            onPressed: () => browser.setViewMode(ViewMode.icons),
            isFirst: true,
          ),
          Container(width: 1, height: 18, color: palette.divider),
          _ViewModeButton(
            icon: CupertinoIcons.list_bullet,
            tooltip: 'List',
            selected: browser.viewMode == ViewMode.list,
            onPressed: () => browser.setViewMode(ViewMode.list),
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _ViewModeButton extends StatefulWidget {
  const _ViewModeButton({
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
  State<_ViewModeButton> createState() => _ViewModeButtonState();
}

class _ViewModeButtonState extends State<_ViewModeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final bg = widget.selected
        ? palette.sidebarSelected
        : (_hover ? palette.sidebarHover : null);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          width: 32,
          height: 26,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.horizontal(
              left: widget.isFirst
                  ? const Radius.circular(5)
                  : Radius.zero,
              right: widget.isLast
                  ? const Radius.circular(5)
                  : Radius.zero,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 14,
            color: widget.selected ? palette.text : palette.subtleText,
          ),
        ),
      ),
    );
  }
}

class _ToolbarIconButton extends StatefulWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 36,
    this.highlighted = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final bool highlighted;

  @override
  State<_ToolbarIconButton> createState() => _ToolbarIconButtonState();
}

class _ToolbarIconButtonState extends State<_ToolbarIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final enabled = widget.onPressed != null;
    final iconSize = (widget.size * 0.5).clamp(14.0, 22.0);
    final bg = widget.highlighted
        ? palette.sidebarSelected
        : (_hover && enabled ? palette.sidebarHover : null);
    final iconColor = enabled
        ? (widget.highlighted ? palette.accent : palette.subtleText)
        : palette.subtleText.withValues(alpha: 0.4);
    return MouseRegion(
      cursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            widget.icon,
            size: iconSize,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

class _ConnectionPill extends StatefulWidget {
  const _ConnectionPill({
    required this.connected,
    required this.model,
    required this.onTap,
  });

  final bool connected;
  final String? model;
  final VoidCallback onTap;

  @override
  State<_ConnectionPill> createState() => _ConnectionPillState();
}

class _ConnectionPillState extends State<_ConnectionPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? palette.sidebarHover : palette.cardBg,
            border: Border.all(color: palette.divider),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.connected ? palette.success : palette.danger,
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  widget.model ?? (widget.connected ? 'connected' : 'offline'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.text,
                    fontWeight: FontWeight.w500,
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

class _SegmentedHeader extends StatelessWidget {
  const _SegmentedHeader({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      child: CupertinoSlidingSegmentedControl<int>(
        groupValue: index,
        children: const {
          0: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text('Info', style: TextStyle(fontSize: 13)),
          ),
          1: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text('Chat', style: TextStyle(fontSize: 13)),
          ),
          2: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text('Workflows', style: TextStyle(fontSize: 13)),
          ),
        },
        onValueChanged: (v) => onChanged(v ?? 0),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../providers/browser_provider.dart';
import '../providers/search_provider.dart';
import '../providers/settings_provider.dart';
import '../theme.dart';
import '../utils/responsive.dart';
import '../widgets/chat_panel.dart';
import '../widgets/file_list_view.dart';
import '../widgets/file_op_progress.dart';
import '../widgets/file_drag_drop.dart';
import '../widgets/search_bar.dart';
import '../widgets/info_panel.dart';
import '../widgets/path_status_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/terminal_panel.dart';
import '../widgets/window_chrome.dart';
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
    final colors = ShadTheme.of(context).colorScheme;
    final searching = context.select<SearchProvider, bool>((s) => s.isActive);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          decoration: BoxDecoration(
            color: colors.muted,
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: const FolderSearchBar(),
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

  // Cmd+J (macOS) / Ctrl+J (others) toggles the integrated terminal,
  // matching VSCode's Toggle Panel shortcut. Runs ahead of focus dispatch
  // so the terminal itself can't swallow the shortcut.
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyJ) return false;
    final modOk = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    if (!modOk) return false;
    _toggleTerminal();
    return true;
  }

  void _openSettings() => showSettingsDialog(context);

  void _toggleDrawer() => setState(() => _drawerOpen = !_drawerOpen);
  void _closeDrawer() {
    if (_drawerOpen) setState(() => _drawerOpen = false);
  }

  void _toggleTerminal() => setState(() => _terminalOpen = !_terminalOpen);
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
    final colors = ShadTheme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final compact = isCompactWidth(width);

    // Snap drawer shut if user resizes back to wide layout.
    if (!compact && _drawerOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _drawerOpen = false);
      });
    }

    // A ColoredBox is enough in place of CupertinoPageScaffold: both layouts
    // apply their own SafeArea, and a desktop file manager has no on-screen
    // keyboard for the scaffold's inset handling to work around.
    return ColoredBox(
      color: colors.background,
      child: compact
          ? _CompactLayout(
              tab: _compactTab,
              onTabChanged: (i) => setState(() => _compactTab = i),
              drawerOpen: _drawerOpen,
              onToggleDrawer: _toggleDrawer,
              onCloseDrawer: _closeDrawer,
              onSettings: _openSettings,
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
              terminalOpen: _terminalOpen,
              terminalHeight: _terminalHeight,
              onToggleTerminal: _toggleTerminal,
              onCloseTerminal: _closeTerminal,
              onResizeTerminal: _resizeTerminal,
              overviewKey: _overviewKey,
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
  final bool terminalOpen;
  final double terminalHeight;
  final VoidCallback onToggleTerminal;
  final VoidCallback onCloseTerminal;
  final ValueChanged<double> onResizeTerminal;
  final GlobalKey<SystemOverviewViewState> overviewKey;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
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
                          _VDivider(color: colors.border),
                        ],
                      ),
              ),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    _WideTopBar(
                      onSettings: onSettings,
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
                    Expanded(
                      // LayoutBuilder so the terminal knows how much room the
                      // content area actually has: a Column child can't read
                      // its own available height, and an unclamped fixed-height
                      // panel overflows a short window.
                      child: LayoutBuilder(
                        builder: (ctx, c) => Column(
                          children: [
                            Expanded(
                              child: _centerBody(centerView, overviewKey),
                            ),
                            if (terminalOpen)
                              TerminalPanel(
                                cwd: cwd,
                                height: clampTerminalHeight(
                                  terminalHeight,
                                  c.maxHeight,
                                ),
                                onResize: onResizeTerminal,
                                onClose: onCloseTerminal,
                              ),
                          ],
                        ),
                      ),
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
                          _VDivider(color: colors.border),
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
    final colors = ShadTheme.of(context).colorScheme;
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
                onToggleTerminal: onToggleTerminal,
                terminalOpen: terminalOpen,
                title: tab == 0 ? _centerTitle(centerView) : '',
              ),
              Expanded(
                // Same reason as the wide layout: the terminal shares the
                // content area rather than the chrome, so it can be measured
                // against a known height and clamped.
                child: LayoutBuilder(
                  builder: (ctx, c) => Column(
                    children: [
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
                          height: clampTerminalHeight(
                            terminalHeight,
                            c.maxHeight,
                          ),
                          onResize: onResizeTerminal,
                          onClose: onCloseTerminal,
                        ),
                    ],
                  ),
                ),
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
              border: Border(right: BorderSide(color: colors.border)),
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
    final colors = ShadTheme.of(context).colorScheme;

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      // Doubles as the window's title bar. With the sidebar shown the macOS
      // traffic lights sit over the sidebar, which reserves the space itself,
      // so only the collapsed case needs the gap here.
      child: WindowTitleBar(
        atWindowEdge: sidebarCollapsed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _controls(context),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final browser = context.watch<BrowserProvider>();
    final colors = ShadTheme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (ctx, c) {
        // Progressively shed non-essential controls as the center pane
        // narrows (both side panels open on a small window), so the row
        // never overflows. Priority, widest-first: full model pill →
        // grid/list toggle → back/forward nav. The sidebar/panel toggles,
        // terminal, connection dot and settings always stay.
        // Measured against text-scale-normalised width: the thresholds were
        // tuned for 13px labels, and at a 2x OS text size the pill and the
        // folder label are twice as wide, so a bar that "fits" by raw pixels
        // still overflows. Dividing by the scale sheds controls at the width
        // where they would actually stop fitting.
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final w = c.maxWidth / (scale <= 0 ? 1 : scale);
        final showFullPill = w >= 440;
        final showViewToggle = w >= 360;
        final showNav = w >= 290;
        return Row(
          children: [
            _ToolbarIconButton(
              icon: LucideIcons.panelLeft,
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
                  icon: LucideIcons.chevronLeft,
                  tooltip: 'Back',
                  onPressed: browser.canGoBack ? browser.goBack : null,
                  size: 30,
                ),
                _ToolbarIconButton(
                  icon: LucideIcons.chevronRight,
                  tooltip: 'Forward',
                  onPressed: browser.canGoForward ? browser.goForward : null,
                  size: 30,
                ),
                // Up sits with Back/Forward rather than on its own row —
                // they're the same kind of control, and the path itself
                // lives in the status bar at the bottom.
                _ToolbarIconButton(
                  icon: LucideIcons.arrowUp,
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
                    color: colors.foreground,
                  ),
                ),
              ),
              if (centerView == CenterView.systemOverview) ...[
                _ToolbarIconButton(
                  icon: LucideIcons.refreshCw,
                  tooltip: 'Refresh',
                  onPressed: onRefreshOverview,
                  size: 30,
                ),
                const SizedBox(width: 4),
              ],
            ],
            // Tail group: terminal, AI model, settings, panel toggle.
            _ToolbarIconButton(
              icon: LucideIcons.terminal,
              tooltip: 'Terminal (${Platform.isMacOS ? "⌘" : "Ctrl"}+J)',
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
              icon: LucideIcons.settings,
              tooltip: 'Settings',
              onPressed: onSettings,
              size: 30,
            ),
            const SizedBox(width: 4),
            _ToolbarIconButton(
              icon: LucideIcons.panelRight,
              tooltip: rightPanelCollapsed ? 'Show Panel' : 'Hide Panel',
              onPressed: onToggleRightPanel,
              size: 30,
              highlighted: !rightPanelCollapsed,
            ),
            // Windows and Linux have no native caption left, so the window's
            // own controls live at the trailing edge. Renders nothing on
            // macOS, where AppKit still draws the traffic lights.
            if (windowButtons == WindowButtons.drawn) ...[
              const SizedBox(width: 6),
              const WindowControls(),
            ],
          ],
        );
      },
    );
  }
}

class _CompactTopBar extends StatelessWidget {
  const _CompactTopBar({
    required this.onMenu,
    required this.onSettings,
    required this.onToggleTerminal,
    required this.terminalOpen,
    this.title = '',
  });
  final VoidCallback onMenu;
  final VoidCallback onSettings;
  final VoidCallback onToggleTerminal;
  final bool terminalOpen;

  /// When non-empty, shown in place of the current-folder label (used when a
  /// non-file page occupies the center pane).
  final String title;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final browser = context.watch<BrowserProvider>();
    final colors = ShadTheme.of(context).colorScheme;

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      // Also the window's title bar. There is no sidebar beside this one, so
      // it always sits at the window's leading edge and always has to clear
      // the macOS traffic lights — previously it did not, and they overlapped
      // the menu button.
      child: WindowTitleBar(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _controls(context, settings, browser, colors),
        ),
      ),
    );
  }

  Widget _controls(
    BuildContext context,
    SettingsProvider settings,
    BrowserProvider browser,
    ShadColorScheme colors,
  ) {
    return Row(
      children: [
        _ToolbarIconButton(
          icon: LucideIcons.panelLeft,
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
                    color: colors.foreground,
                  ),
                )
              : _CurrentFolderLabel(path: browser.currentPath),
        ),
        const SizedBox(width: 4),
        _ToolbarIconButton(
          icon: LucideIcons.terminal,
          tooltip: 'Terminal',
          onPressed: onToggleTerminal,
          highlighted: terminalOpen,
        ),
        _ConnectionDot(connected: settings.connected, onTap: onSettings),
        _ToolbarIconButton(
          icon: LucideIcons.settings,
          tooltip: 'Settings',
          onPressed: onSettings,
        ),
        if (windowButtons == WindowButtons.drawn) ...[
          const SizedBox(width: 4),
          const WindowControls(),
        ],
      ],
    );
  }
}

class _CurrentFolderLabel extends StatelessWidget {
  const _CurrentFolderLabel({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final name = _displayName(path);
    return Text(
      name,
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: colors.foreground,
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
    final colors = ShadTheme.of(context).colorScheme;
    return ShadTooltip(
      builder: (_) => Text(
        connected ? 'Connected — open Settings' : 'Offline — open Settings',
        style: const TextStyle(fontSize: 11.5),
      ),
      child: ShadIconButton.ghost(
        width: 26,
        height: 26,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected ? palette.success : colors.destructive,
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
    (LucideIcons.folder, 'Files'),
    (LucideIcons.info, 'Info'),
    (LucideIcons.messageSquare, 'Chat'),
    (LucideIcons.zap, 'Flows'),
  ];

  @override
  Widget build(BuildContext context) {
    // Kept hand-rolled: shadcn ships no bottom-nav component, and ShadTabs is a
    // horizontal pill bar with no icon-over-label form.
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      // minHeight, not a fixed height: the icon-over-label stack is 34px at the
      // default text size but taller once the OS text size is scaled up, and a
      // hard 52 clipped the label instead of letting the bar grow.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: List.generate(_items.length, (i) {
            final selected = i == index;
            final item = _items[i];
            final tint = selected ? colors.primary : colors.mutedForeground;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.$1, size: 22, color: tint),
                      const SizedBox(height: 2),
                      Text(
                        item.$2,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: tint,
                        ),
                      ),
                    ],
                  ),
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
    // Kept hand-rolled: a joined pair with shared borders and per-end corner
    // radii, sized to fit a 48px toolbar that already sheds controls for space.
    // ShadTabs brings its own padding and reads noticeably chunkier here.
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _ViewModeButton(
            icon: LucideIcons.layoutGrid,
            tooltip: 'Icons',
            selected: browser.viewMode == ViewMode.icons,
            onPressed: () => browser.setViewMode(ViewMode.icons),
            isFirst: true,
          ),
          Container(width: 1, height: 18, color: colors.border),
          _ViewModeButton(
            icon: LucideIcons.list,
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
    final colors = ShadTheme.of(context).colorScheme;
    final bg = widget.selected
        ? palette.sidebarSelected
        : (_hover ? colors.accent : null);

    // `tooltip` used to be dead — nothing here rendered it. ShadTooltip does.
    return ShadTooltip(
      builder: (_) =>
          Text(widget.tooltip, style: const TextStyle(fontSize: 11.5)),
      child: MouseRegion(
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
                left: widget.isFirst ? const Radius.circular(5) : Radius.zero,
                right: widget.isLast ? const Radius.circular(5) : Radius.zero,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 14,
              color:
                  widget.selected ? colors.foreground : colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// The toolbar's workhorse control. [ShadIconButton.ghost] supplies hover and
/// press feedback, so the hand-rolled MouseRegion/hover state this used to
/// carry is gone; only the "highlighted" (toggle-is-on) look needs overriding,
/// since shadcn has no selected state for an icon button.
class _ToolbarIconButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final enabled = onPressed != null;

    final button = ShadIconButton.ghost(
      width: size,
      height: size,
      padding: EdgeInsets.zero,
      iconSize: (size * 0.5).clamp(14.0, 22.0),
      // ShadIconButton keys its disabled look off `enabled`, not off a null
      // callback, so both have to be set.
      enabled: enabled,
      onPressed: onPressed,
      backgroundColor: highlighted ? palette.sidebarSelected : null,
      foregroundColor: highlighted ? colors.primary : colors.mutedForeground,
      icon: Icon(icon),
    );

    // `tooltip` used to be dead: nothing rendered it at any of the call sites.
    if (tooltip == null) return button;
    return ShadTooltip(
      builder: (_) => Text(tooltip!, style: const TextStyle(fontSize: 11.5)),
      child: button,
    );
  }
}

class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill({
    required this.connected,
    required this.model,
    required this.onTap,
  });

  final bool connected;
  final String? model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    return ShadBadge.outline(
      onPressed: onTap,
      hoverBackgroundColor: colors.accent,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? palette.success : colors.destructive,
            ),
          ),
          const SizedBox(width: 8),
          // Self-limiting rather than Flexible: the pill sits in a Row that
          // already has an Expanded (the title/folder label), and a second flex
          // child would split the free space and leave dead air at the right.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              model ?? (connected ? 'connected' : 'offline'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: colors.foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedHeader extends StatelessWidget {
  const _SegmentedHeader({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  // "Flows" rather than "Workflows", matching the compact layout's bottom tab
  // bar. A non-scrollable ShadTabs gives each tab an equal Expanded share and
  // its label cannot ellipsize, so an over-long one overflows the bar outright.
  // The right panel narrows to 320px below a 1100px window, which leaves ~69px
  // of label room per tab — not enough for "Workflows" even at zero padding.
  static const _labels = ['Info', 'Chat', 'Flows'];
  static const _icons = [
    LucideIcons.info,
    LucideIcons.messageSquare,
    LucideIcons.zap,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    // A tab label can't ellipsize (see above), so at large accessibility text
    // sizes the labels are swapped for their icons instead of overflowing the
    // bar. 15px is where a three-label strip stops fitting a 320px panel.
    final scaledLabel = MediaQuery.textScalerOf(context).scale(13);
    final iconsOnly = scaledLabel > 15;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.muted,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: ShadTabs<int>(
        value: index,
        gap: 0,
        onChanged: onChanged,
        tabs: [
          for (var i = 0; i < _labels.length; i++)
            ShadTab(
              value: i,
              // Trimmed from Shad's default 12 to buy back label room at the
              // narrow (320px) panel width.
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: iconsOnly
                  ? ShadTooltip(
                      builder: (_) => Text(_labels[i]),
                      child: Icon(_icons[i], size: 16),
                    )
                  : Text(_labels[i], style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

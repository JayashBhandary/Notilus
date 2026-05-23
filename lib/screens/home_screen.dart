import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../providers/settings_provider.dart';
import '../theme.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/chat_panel.dart';
import '../widgets/file_list_view.dart';
import '../widgets/info_panel.dart';
import '../widgets/path_status_bar.dart';
import '../widgets/sidebar.dart';
import '../widgets/workflow_tab.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _rightTab = 0;

  void _openSettings() {
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);

    return CupertinoPageScaffold(
      backgroundColor: palette.contentBg,
      child: Column(
        children: [
          _TopBar(onSettings: _openSettings),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Sidebar(),
                _Divider(color: palette.divider),
                const Expanded(flex: 3, child: FileListView()),
                _Divider(color: palette.divider),
                SizedBox(
                  width: 400,
                  child: Column(
                    children: [
                      _SegmentedHeader(
                        index: _rightTab,
                        onChanged: (v) => setState(() => _rightTab = v),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _rightTab,
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
          const PathStatusBar(),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: color);
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onSettings});
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final leadingInset = isMac ? 78.0 : 12.0;

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      padding: EdgeInsets.only(left: leadingInset, right: 8),
      child: Row(
        children: [
          _ToolbarIconButton(
            icon: CupertinoIcons.arrow_clockwise,
            tooltip: 'Refresh',
            onPressed: browser.currentPath.isEmpty ? null : browser.refresh,
          ),
          const SizedBox(width: 6),
          _ViewModeToggle(browser: browser),
          const SizedBox(width: 10),
          const Expanded(child: BreadcrumbBar()),
          const SizedBox(width: 8),
          _ConnectionPill(
            connected: settings.connected,
            model: settings.model,
            onTap: onSettings,
          ),
          const SizedBox(width: 4),
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
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  State<_ToolbarIconButton> createState() => _ToolbarIconButtonState();
}

class _ToolbarIconButtonState extends State<_ToolbarIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final enabled = widget.onPressed != null;
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
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _hover && enabled ? palette.sidebarHover : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: enabled
                ? palette.subtleText
                : palette.subtleText.withValues(alpha: 0.4),
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

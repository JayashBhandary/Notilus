import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../providers/browser_provider.dart';
import '../services/file_service.dart';
import '../theme.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    this.width = 210,
    this.onNavigate,
    this.onFocusCenter,
  });

  /// Fixed width when shown inline. The drawer version sizes itself via
  /// constraints from the surrounding overlay.
  final double width;

  /// Called after the user picks any navigation target. Use this to close
  /// the drawer in compact mode. Inline (wide) usage leaves this null.
  final VoidCallback? onNavigate;

  /// Called when the user selects anything that changes the central content
  /// pane (a folder or a page). Compact layout uses this to focus the center
  /// tab; wide layout leaves it null.
  final VoidCallback? onFocusCenter;

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final shortcuts = browser.shortcuts.entries
        .where((e) => e.value != null && e.value!.isNotEmpty)
        .toList();
    final drives = browser.drives;

    void after(VoidCallback action) {
      action();
      onFocusCenter?.call();
      onNavigate?.call();
    }

    // On macOS the traffic lights sit at the window's top-left, which is
    // now over the sidebar. Push the first item down so it doesn't overlap.
    final isDesktopMac =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final topPadding = isDesktopMac ? 36.0 : 14.0;

    return Container(
      width: width,
      color: palette.sidebarBg,
      child: SafeArea(
        right: false,
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(top: topPadding, bottom: 16),
          children: [
            const _SectionHeader(label: 'System'),
            _SidebarItem(
              label: 'System Overview',
              icon: LucideIcons.gauge,
              selected: browser.centerView == CenterView.systemOverview,
              onTap: () => after(
                () => browser.showCenterView(CenterView.systemOverview),
              ),
            ),
            _SidebarItem(
              label: 'Duplicate Finder',
              icon: LucideIcons.copy,
              selected: browser.centerView == CenterView.duplicates,
              onTap: () => after(
                () => browser.showCenterView(CenterView.duplicates),
              ),
            ),
            _SidebarItem(
              label: 'File Transfer',
              icon: LucideIcons.arrowDownUp,
              selected: browser.centerView == CenterView.transfers,
              onTap: () => after(
                () => browser.showCenterView(CenterView.transfers),
              ),
            ),
            const SizedBox(height: 14),
            const _SectionHeader(label: 'Favorites'),
            ...shortcuts.map((e) {
              final selected = browser.centerView == CenterView.files &&
                  browser.currentPath == e.value;
              return _SidebarItem(
                label: e.key,
                icon: _iconForShortcut(e.key),
                selected: selected,
                onTap: () => after(() => browser.navigateTo(e.value!)),
              );
            }),
            const SizedBox(height: 14),
            _SectionHeader(
              label: 'Locations',
              trailing: GestureDetector(
                onTap: browser.refreshDrives,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Icon(
                    LucideIcons.refreshCw,
                    size: 12,
                    color: palette.sidebarHeader,
                    semanticLabel: 'Refresh drives',
                  ),
                ),
              ),
            ),
            if (drives.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  'No drives detected',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.mutedForeground,
                  ),
                ),
              )
            else
              ...drives.map((d) {
                final selected = browser.centerView == CenterView.files &&
                    browser.currentPath == d.path;
                return _SidebarItem(
                  label: d.name,
                  icon: _iconForDrive(d),
                  iconColor:
                      d.isRoot ? colors.mutedForeground : palette.folderIcon,
                  selected: selected,
                  onTap: () => after(() => browser.navigateTo(d.path)),
                );
              }),
            const SizedBox(height: 14),
            const _SectionHeader(label: 'Tags'),
            ..._kTags.map(
              (t) => _TagItem(label: t.name, color: t.color),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForShortcut(String name) {
    switch (name) {
      case 'Home':
        return LucideIcons.house;
      case 'Desktop':
        return LucideIcons.monitor;
      case 'Documents':
        return LucideIcons.fileText;
      case 'Downloads':
        return LucideIcons.circleArrowDown;
      default:
        return LucideIcons.folder;
    }
  }

  IconData _iconForDrive(DriveEntry d) =>
      d.isRoot ? LucideIcons.laptop : LucideIcons.hardDrive;
}

class _TagSpec {
  const _TagSpec(this.name, this.color);
  final String name;
  final Color color;
}

const List<_TagSpec> _kTags = [
  _TagSpec('Red', Color(0xFFFF453A)),
  _TagSpec('Orange', Color(0xFFFF9F0A)),
  _TagSpec('Yellow', Color(0xFFFFD60A)),
  _TagSpec('Green', Color(0xFF30D158)),
  _TagSpec('Blue', Color(0xFF0A84FF)),
  _TagSpec('Purple', Color(0xFFBF5AF2)),
  _TagSpec('Gray', Color(0xFF8E8E93)),
];

class _TagItem extends StatefulWidget {
  const _TagItem({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  State<_TagItem> createState() => _TagItemState();
}

class _TagItemState extends State<_TagItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Intentionally inert: tag filtering does not exist yet (no tag field
        // on FileEntry and nowhere to persist one). The rows are kept because
        // they were already shipping, not because they do anything.
        onTap: () {},
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _hover ? colors.accent : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.foreground,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                letterSpacing: 0.4,
                color: palette.sidebarHeader,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.iconColor,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    // sidebarSelected has no shadcn slot — colors.accent is the hover surface,
    // so using it for both would erase the selected/hovered distinction.
    final bg = widget.selected
        ? palette.sidebarSelected
        : (_hover ? colors.accent : null);

    final defaultIconColor =
        widget.selected ? colors.primary : colors.mutedForeground;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: widget.iconColor ?? defaultIconColor,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.foreground,
                    fontWeight: widget.selected
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

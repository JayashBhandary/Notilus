import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../models/media_kind.dart';
import '../models/remote/remote_connection.dart';
import '../providers/browser_provider.dart';
import '../screens/media_screen.dart' show iconForMediaKind;
import '../services/file_service.dart';
import '../services/remote/remote_hub.dart';
import '../services/remote/remote_path.dart';
import '../theme.dart';
import '../utils/platform.dart';
import 'desk_context_menu.dart';
import 'remote/remote_source_dialog.dart';

/// A row for the sidebar's pinned footer.
///
/// These are the app-level destinations — the assistant, the selected file's
/// details, settings — which on a phone have nowhere else to live now that its
/// top bar carries only what the open folder needs.
class SidebarAction {
  const SidebarAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  /// Shown at the end of the row (a status dot, a count).
  final Widget? trailing;
}

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    this.width = 210,
    this.onNavigate,
    this.onFocusCenter,
    this.footer = const <SidebarAction>[],
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

  /// Rows pinned below the scrolling list. Empty on the wide layout, where the
  /// same destinations have their own chrome.
  final List<SidebarAction> footer;

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    // The hub is read from its singleton rather than through Provider: it is
    // the same object either way, and a widget that can be dropped into a
    // harness with only a BrowserProvider around it stays droppable.
    final hub = RemoteHub.instance;
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

    /// For a tap that leaves the centre pane alone but is still the end of
    /// what you came to the sidebar for — opening a dialog over it, or a row
    /// that does nothing yet. The drawer shuts either way: on a phone it
    /// covers the thing the tap was about.
    void dismiss() => onNavigate?.call();

    // On macOS the traffic lights sit at the window's top-left, which is
    // now over the sidebar. Push the first item down so it doesn't overlap.
    final isDesktopMac =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final topPadding = isDesktopMac ? 36.0 : 14.0;

    // The tools that read a whole machine, and the server that publishes part
    // of it, are desktop-only — see `utils/platform.dart`. On a phone the list
    // is only what you can browse, so it leads with the places instead.
    final tools = <Widget>[
      const _SectionHeader(label: 'System'),
      if (hasMachineTools) ...[
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
      ],
      _SidebarItem(
        label: 'File Transfer',
        icon: LucideIcons.arrowDownUp,
        selected: browser.centerView == CenterView.transfers,
        onTap: () => after(
          () => browser.showCenterView(CenterView.transfers),
        ),
      ),
      if (canHostShares)
        _SidebarItem(
          label: 'File Sharing',
          icon: LucideIcons.share2,
          selected: browser.centerView == CenterView.sharing,
          onTap: () => after(
            () => browser.showCenterView(CenterView.sharing),
          ),
        ),
    ];

    final favorites = <Widget>[
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
    ];

    final media = <Widget>[
      const _SectionHeader(label: 'Media'),
      ...MediaKind.values.map(
        (kind) => _SidebarItem(
          label: kind.label,
          icon: iconForMediaKind(kind),
          selected: browser.centerView == centerViewForMedia(kind),
          onTap: () => after(
            () => browser.showCenterView(centerViewForMedia(kind)),
          ),
        ),
      ),
    ];

    final locations = <Widget>[
      _SectionHeader(
        label: 'Locations',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Adding a cloud source sits here rather than in Settings
            // because this is the list it joins: a remote is a location,
            // and the row it produces behaves like the drives above it.
            _HeaderAction(
              icon: LucideIcons.plus,
              tooltip: 'Add a remote source',
              onTap: () => _addRemote(context, after, dismiss),
            ),
            _HeaderAction(
              icon: LucideIcons.refreshCw,
              tooltip: 'Refresh drives',
              onTap: browser.refreshDrives,
            ),
          ],
        ),
      ),
      if (drives.isEmpty && hub.isEmpty)
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
            iconColor: d.isRoot ? colors.mutedForeground : palette.folderIcon,
            selected: selected,
            onTap: () => after(() => browser.navigateTo(d.path)),
          );
        }),
      // Mounted cloud sources, in the same list as the physical drives:
      // to the rest of the app a bucket is just another place files are.
      ...hub.connections.map(
        (connection) => _RemoteItem(
          connection: connection,
          status: hub.statusOf(connection.id),
          error: hub.errorOf(connection.id),
          selected: browser.centerView == CenterView.files &&
              VPath.connectionOf(browser.currentPath) == connection.id,
          onTap: () => after(
            () => browser.navigateTo(VPath.root(connection.id)),
          ),
          onOpen: (path) => after(() => browser.navigateTo(path)),
          onLeave: dismiss,
        ),
      ),
      if (hub.isEmpty)
        _SidebarItem(
          label: 'Add remote source…',
          icon: LucideIcons.cloudUpload,
          selected: false,
          onTap: () => _addRemote(context, after, dismiss),
        ),
    ];

    final tags = <Widget>[
      const _SectionHeader(label: 'Tags'),
      ..._kTags.map(
        (t) => _TagItem(label: t.name, color: t.color, onTap: dismiss),
      ),
    ];

    // Phone order puts the places first — the drives and the remote sources
    // are what a client is opened to reach, and the tools below them are a
    // short list once the desktop-only ones are gone.
    final sections = isMobilePlatform
        ? [locations, favorites, media, tools, tags]
        : [tools, favorites, media, locations, tags];

    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Container(
        width: width,
        color: palette.sidebarBg,
        child: SafeArea(
          right: false,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(top: topPadding, bottom: 16),
                  children: [
                    for (final (index, section) in sections.indexed) ...[
                      if (index > 0) const SizedBox(height: 14),
                      ...section,
                    ],
                  ],
                ),
              ),
              // Pinned rather than in the list: settings and the assistant are
              // reached from anywhere in a long list of drives, so they can't
              // sit past the end of the scroll.
              if (footer.isNotEmpty)
                Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: colors.border)),
                  ),
                  child: SafeArea(
                    top: false,
                    right: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        children: [
                          for (final action in footer)
                            _SidebarItem(
                              label: action.label,
                              icon: action.icon,
                              selected: action.selected,
                              trailing: action.trailing,
                              onTap: () {
                                action.onTap();
                                onNavigate?.call();
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
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

  /// Opens the add-source dialog and, if a source was added, navigates to it —
  /// the point of adding one is to look at it.
  Future<void> _addRemote(
    BuildContext context,
    void Function(VoidCallback) after,
    VoidCallback dismiss,
  ) async {
    final browser = context.read<BrowserProvider>();
    // Out of the way first: the dialog is the whole screen on a phone, and
    // coming back from it to a drawer still standing open reads as a step not
    // taken.
    dismiss();
    final id = await showRemoteSourceDialog(context);
    if (id == null) return;
    after(() => browser.navigateTo(VPath.root(id)));
  }
}

/// A mounted remote source. Carries a status dot — connecting, ready, or
/// broken — because a network location can fail in ways a local disk can't,
/// and the right-click menu that manages it.
class _RemoteItem extends StatefulWidget {
  const _RemoteItem({
    required this.connection,
    required this.status,
    required this.error,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    required this.onLeave,
  });

  final RemoteConnection connection;
  final RemoteStatus status;
  final String? error;
  final bool selected;
  final VoidCallback onTap;

  /// Navigate to a path the row's menu picked. Routed out so the menu goes
  /// through the same "navigate, then shut the drawer" path as a plain tap.
  final ValueChanged<String> onOpen;

  /// The menu is done with the sidebar — it put a dialog over it, or ejected
  /// the row itself.
  final VoidCallback onLeave;

  @override
  State<_RemoteItem> createState() => _RemoteItemState();
}

class _RemoteItemState extends State<_RemoteItem> {
  bool _hover = false;

  void _showMenu(BuildContext context, Offset position) {
    final browser = context.read<BrowserProvider>();
    final connection = widget.connection;
    showDeskContextMenu(
      context,
      globalPosition: position,
      items: [
        DeskMenuItem(
          label: 'Open',
          icon: LucideIcons.folderOpen,
          onTap: () => widget.onOpen(VPath.root(connection.id)),
        ),
        // Reconnect is the one action that leaves the drawer standing: what it
        // changes is this row's own status dot, so hiding the row to show the
        // result would be the wrong way round.
        DeskMenuItem(
          label: 'Reconnect',
          icon: LucideIcons.refreshCw,
          onTap: () {
            RemoteHub.instance.unmount(connection.id);
            if (VPath.connectionOf(browser.currentPath) == connection.id) {
              browser.refresh();
            }
          },
        ),
        DeskMenuItem.divider(),
        DeskMenuItem(
          label: 'Edit…',
          icon: LucideIcons.settings,
          onTap: () {
            widget.onLeave();
            showRemoteSourceDialog(context, existing: connection);
          },
        ),
        DeskMenuItem(
          label: 'Eject',
          icon: LucideIcons.circleMinus,
          onTap: () {
            widget.onLeave();
            RemoteHub.instance.unmount(connection.id);
          },
        ),
        DeskMenuItem.divider(),
        DeskMenuItem(
          label: 'Remove source…',
          icon: LucideIcons.trash,
          onTap: () {
            widget.onLeave();
            confirmRemoveRemote(context, connection);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final colors = ShadTheme.of(context).colorScheme;
    final bg = widget.selected
        ? palette.sidebarSelected
        : (_hover ? colors.accent : null);

    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition),
        onLongPressStart: (details) =>
            _showMenu(context, details.globalPosition),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(
                widget.connection.kind.icon,
                size: 14,
                color: widget.status == RemoteStatus.error
                    ? colors.destructive
                    : (widget.selected
                        ? colors.primary
                        : colors.mutedForeground),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.connection.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.foreground,
                    fontWeight:
                        widget.selected ? FontWeight.w500 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _StatusDot(status: widget.status, palette: palette),
            ],
          ),
        ),
      ),
    );

    final error = widget.error;
    if (error == null) return row;
    return ShadTooltip(
      builder: (_) => Text(error, style: const TextStyle(fontSize: 11.5)),
      child: row,
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.palette});

  final RemoteStatus status;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    // Idle draws nothing: a source that simply hasn't been opened yet is not
    // a state worth a light.
    if (status == RemoteStatus.idle) return const SizedBox(width: 8);
    final color = switch (status) {
      RemoteStatus.ready => palette.success,
      RemoteStatus.error => colors.destructive,
      RemoteStatus.connecting => colors.mutedForeground,
      RemoteStatus.idle => colors.mutedForeground,
    };
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

/// A small icon button for a section header — the `+` and the refresh arrow.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return ShadTooltip(
      builder: (_) => Text(tooltip, style: const TextStyle(fontSize: 11.5)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              icon,
              size: 12,
              color: palette.sidebarHeader,
              semanticLabel: tooltip,
            ),
          ),
        ),
      ),
    );
  }
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
  const _TagItem({
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;

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
        // Tag filtering does not exist yet — no tag field on FileEntry and
        // nowhere to persist one — so the tap files nothing away. It still
        // shuts the drawer, because a row that looks selectable and answers a
        // tap with nothing at all reads as a broken screen rather than an
        // unfinished feature.
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
    this.trailing,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color? iconColor;
  final Widget? trailing;

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
          // A 26px row is a mouse's list item. In the phone drawer the same
          // row is a tap target, so it grows to clear the touch floor — see
          // `kTouchTargetMin`.
          padding: EdgeInsets.symmetric(
            horizontal: 8,
            vertical: isMobilePlatform ? 11 : 3,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: isMobilePlatform ? 17 : 14,
                color: widget.iconColor ?? defaultIconColor,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: isMobilePlatform ? 15 : 12.5,
                    color: colors.foreground,
                    fontWeight:
                        widget.selected ? FontWeight.w500 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 6),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

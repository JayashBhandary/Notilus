import 'package:flutter/cupertino.dart';

import '../theme.dart';

class DeskMenuItem {
  DeskMenuItem({
    required this.label,
    this.icon,
    this.trailing,
    this.checked,
    this.enabled = true,
    this.onTap,
    this.submenu,
  })  : isDivider = false,
        assert(onTap != null || submenu != null || enabled == false);

  DeskMenuItem.divider()
      : label = '',
        icon = null,
        trailing = null,
        checked = null,
        enabled = false,
        onTap = null,
        submenu = null,
        isDivider = true;

  final String label;
  final IconData? icon;
  final IconData? trailing;
  final bool? checked;
  final bool enabled;
  final VoidCallback? onTap;
  final List<DeskMenuItem>? submenu;
  final bool isDivider;
}

const double _menuWidth = 220;
const double _itemHeight = 28;
const double _dividerHeight = 9;

// The one context menu allowed on screen at a time. Opening a new one closes
// any existing one, so overlapping triggers can never stack two menus.
OverlayEntry? _activeMenu;

Future<void> showDeskContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<DeskMenuItem> items,
}) async {
  // Tear down any menu that's still open before showing the new one.
  final previous = _activeMenu;
  if (previous != null && previous.mounted) previous.remove();
  _activeMenu = null;

  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;

  void dismiss() {
    if (entry.mounted) entry.remove();
    if (identical(_activeMenu, entry)) _activeMenu = null;
  }

  entry = OverlayEntry(
    builder: (ctx) => _DeskMenuLayer(
      anchor: globalPosition,
      items: items,
      onDismiss: dismiss,
    ),
  );
  _activeMenu = entry;
  overlay.insert(entry);
}

class _DeskMenuLayer extends StatelessWidget {
  const _DeskMenuLayer({
    required this.anchor,
    required this.items,
    required this.onDismiss,
  });

  final Offset anchor;
  final List<DeskMenuItem> items;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => onDismiss(),
          ),
        ),
        _MenuPositioned(
          anchor: anchor,
          width: _menuWidth,
          itemCount: items.length,
          dividerCount: items.where((i) => i.isDivider).length,
          child: _DeskMenu(items: items, onDismiss: onDismiss),
        ),
      ],
    );
  }
}

class _MenuPositioned extends StatelessWidget {
  const _MenuPositioned({
    required this.anchor,
    required this.width,
    required this.itemCount,
    required this.dividerCount,
    required this.child,
  });

  final Offset anchor;
  final double width;
  final int itemCount;
  final int dividerCount;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final estHeight =
        (itemCount - dividerCount) * _itemHeight + dividerCount * _dividerHeight + 12;
    double left = anchor.dx;
    double top = anchor.dy;
    if (left + width > size.width - 8) left = size.width - width - 8;
    if (top + estHeight > size.height - 8) top = size.height - estHeight - 8;
    if (left < 8) left = 8;
    if (top < 8) top = 8;
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: child,
    );
  }
}

class _DeskMenu extends StatefulWidget {
  const _DeskMenu({required this.items, required this.onDismiss});
  final List<DeskMenuItem> items;
  final VoidCallback onDismiss;

  @override
  State<_DeskMenu> createState() => _DeskMenuState();
}

class _DeskMenuState extends State<_DeskMenu> {
  int? _openSubmenuIndex;

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        border: Border.all(color: palette.divider),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(widget.items.length, (i) {
          final item = widget.items[i];
          if (item.isDivider) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Container(height: 1, color: palette.divider),
            );
          }
          return _MenuRow(
            item: item,
            isSubmenuOpen: _openSubmenuIndex == i,
            onHover: () {
              if (item.submenu != null && _openSubmenuIndex != i) {
                setState(() => _openSubmenuIndex = i);
              } else if (item.submenu == null && _openSubmenuIndex != null) {
                setState(() => _openSubmenuIndex = null);
              }
            },
            onTap: () {
              if (item.submenu != null) {
                setState(() => _openSubmenuIndex = i);
                return;
              }
              widget.onDismiss();
              item.onTap?.call();
            },
            submenuBuilder: item.submenu == null
                ? null
                : () => _DeskMenu(
                      items: item.submenu!,
                      onDismiss: widget.onDismiss,
                    ),
          );
        }),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.item,
    required this.isSubmenuOpen,
    required this.onHover,
    required this.onTap,
    this.submenuBuilder,
  });

  final DeskMenuItem item;
  final bool isSubmenuOpen;
  final VoidCallback onHover;
  final VoidCallback onTap;
  final Widget Function()? submenuBuilder;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;
  final LayerLink _link = LayerLink();
  OverlayEntry? _submenuEntry;

  @override
  void didUpdateWidget(covariant _MenuRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSubmenuOpen && _submenuEntry == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showSubmenu());
    } else if (!widget.isSubmenuOpen && _submenuEntry != null) {
      _hideSubmenu();
    }
  }

  @override
  void dispose() {
    _hideSubmenu();
    super.dispose();
  }

  void _showSubmenu() {
    if (widget.submenuBuilder == null) return;
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _submenuEntry = OverlayEntry(
      builder: (_) => Positioned(
        width: _menuWidth,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(2, -6),
          child: widget.submenuBuilder!(),
        ),
      ),
    );
    overlay.insert(_submenuEntry!);
  }

  void _hideSubmenu() {
    _submenuEntry?.remove();
    _submenuEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppColors.of(context);
    final enabled = widget.item.enabled;
    final highlight = enabled && (_hover || widget.isSubmenuOpen);
    final textColor = enabled
        ? (highlight ? CupertinoColors.white : palette.text)
        : palette.subtleText.withValues(alpha: 0.55);
    final iconColor = textColor;

    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          setState(() => _hover = true);
          widget.onHover();
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onTap : null,
          child: Container(
            height: _itemHeight,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: highlight ? palette.accent : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: widget.item.checked == true
                      ? Icon(
                          CupertinoIcons.check_mark,
                          size: 13,
                          color: iconColor,
                        )
                      : (widget.item.icon != null
                          ? Icon(
                              widget.item.icon,
                              size: 14,
                              color: iconColor,
                            )
                          : const SizedBox.shrink()),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.item.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: textColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.item.trailing != null)
                  Icon(
                    widget.item.trailing,
                    size: 12,
                    color: iconColor,
                  )
                else if (widget.item.submenu != null)
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 11,
                    color: iconColor,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

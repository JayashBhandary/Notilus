import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme.dart' show kMenuIconSize;

/// One entry in a desktop context menu.
///
/// This stays the authoring model for call sites even though the menu is now
/// rendered by [ShadContextMenu]: it keeps the ~19 declarations in
/// `file_list_view.dart` free of shadcn's `.inset` / leading-padding details,
/// and leaves one place ([_toShadItems]) that has to track the library API.
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

  /// When non-null the row shows a checkmark in the leading slot instead of
  /// [icon], so a toggle reads as on/off.
  final bool? checked;
  final bool enabled;
  final VoidCallback? onTap;
  final List<DeskMenuItem>? submenu;
  final bool isDivider;
}

/// Minimum width, so short menus don't collapse to their longest label.
const double _menuMinWidth = 220;

/// Where a submenu opens relative to its parent row.
///
/// shadcn_ui 0.56 defaults a menu item's submenu to `ShadAnchorAuto` with
/// `targetAnchor: topRight` / `followerAnchor: bottomRight`, which lands the
/// submenu on top of the menu it came from; the parent's own rows then sit
/// above it and swallow the click, so the submenu is unreachable. That
/// reproduces with the library's documented `ShadContextMenuRegion` usage too —
/// it is not a consequence of driving the menu from an overlay.
///
/// It has to be a plain [ShadAnchor] rather than [ShadAnchorAuto]: the auto
/// variant recomputes placement from available space and ignores the requested
/// alignments (overriding it moved the submenu by the offset delta only, and
/// left it on the wrong side).
///
/// Putting the submenu's top-left at the row's top-right opens it rightward,
/// which is what a desktop submenu does — and what this file's hand-rolled
/// version used to do with its LayerLink.
///
/// Mind the parameter names, which read backwards: `childAlignment` is the
/// point on the *overlay* and `overlayAlignment` the point on the *child*. That
/// falls out of the class defaults — `topLeft`/`bottomLeft` is documented as
/// "opens below", which only holds under this reading — and setting them the
/// other way round pushed the submenu off the left edge of the screen.
const ShadAnchorBase _submenuAnchor = ShadAnchor(
  childAlignment: Alignment.topLeft,
  overlayAlignment: Alignment.topRight,
  offset: Offset(4, -6),
);

// The one context menu allowed on screen at a time. Opening a new one closes
// any existing one, so overlapping triggers can never stack two menus.
OverlayEntry? _activeMenu;

/// Opens a context menu at [globalPosition].
///
/// Imperative rather than a [ShadContextMenuRegion] wrapping each row: the list
/// and the grid already funnel every right-click through here, along with the
/// arbitration that decides whether a row or the background claimed the
/// gesture. Anchoring a [ShadContextMenu] in an overlay keeps all of that
/// intact.
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
    builder: (_) => _DeskMenuLayer(
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
    // Dismissal is delegated to ShadContextMenu's own onTapOutside rather than
    // a full-screen barrier of our own. The library coordinates the root menu
    // and every open submenu through one TapRegion group, so it knows a click
    // on a submenu is *inside*; an overlaid barrier steals that pointer-down
    // and tears the tree down before the submenu item can fire.
    //
    // ShadGlobalAnchor positions the popover in screen space, so the trigger
    // child carries no size and needs no placement. It also flips near a screen
    // edge, so the manual viewport clamping this file used to do is gone.
    return ShadContextMenu(
      visible: true,
      anchor: ShadGlobalAnchor(anchor),
      constraints: const BoxConstraints(minWidth: _menuMinWidth),
      onTapOutside: (_) => onDismiss(),
      items: _toShadItems(items, onDismiss),
      child: const SizedBox.shrink(),
    );
  }
}

/// Maps [DeskMenuItem]s onto shadcn's menu widgets, recursing into submenus.
List<Widget> _toShadItems(List<DeskMenuItem> items, VoidCallback dismiss) {
  // Reserve the leading slot for every row only if some row actually uses it,
  // otherwise a menu of plain labels carries a redundant 20px gutter.
  final anyLeading =
      items.any((i) => !i.isDivider && (i.icon != null || i.checked != null));

  return [
    for (final item in items)
      if (item.isDivider)
        // Inset rather than edge-to-edge, and a tight vertical gap, so groups
        // read as separated without the menu growing a band between each one.
        const ShadSeparator.horizontal(
          margin: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          thickness: 1,
        )
      else
        _shadItem(item, dismiss, inset: !anyLeading),
  ];
}

Widget _shadItem(
  DeskMenuItem item,
  VoidCallback dismiss, {
  required bool inset,
}) {
  final hasSubmenu = item.submenu != null;

  // Sizes are pinned rather than inherited: the app-wide IconTheme is 16px,
  // which towers over a 13px label.
  final leading = switch (item) {
    // A toggle shows a tick when on and an empty slot when off, so the label
    // never shifts as it flips.
    DeskMenuItem(checked: final bool checked) => checked
        ? const Icon(LucideIcons.check, size: kMenuIconSize)
        : const SizedBox.square(dimension: kMenuIconSize),
    DeskMenuItem(icon: final IconData icon) =>
      Icon(icon, size: kMenuIconSize),
    _ => null,
  };

  final trailing = item.trailing != null
      ? Icon(item.trailing, size: kMenuIconSize)
      // Submenu chevrons read better a shade smaller than a content glyph.
      : (hasSubmenu
          ? const Icon(LucideIcons.chevronRight, size: kMenuIconSize - 2)
          : null);

  final label = Text(item.label, overflow: TextOverflow.ellipsis);

  // A submenu parent must not dismiss on press — pressing it opens the
  // submenu. Leaves dismiss to whichever leaf is eventually chosen.
  final onPressed = hasSubmenu || !item.enabled || item.onTap == null
      ? null
      : () {
          dismiss();
          item.onTap!.call();
        };

  final subItems =
      hasSubmenu ? _toShadItems(item.submenu!, dismiss) : const <Widget>[];

  if (inset && leading == null) {
    return ShadContextMenuItem.inset(
      enabled: item.enabled,
      trailing: trailing,
      onPressed: onPressed,
      items: subItems,
      anchor: hasSubmenu ? _submenuAnchor : null,
      constraints: const BoxConstraints(minWidth: _menuMinWidth),
      child: label,
    );
  }
  return ShadContextMenuItem(
    enabled: item.enabled,
    leading: leading,
    trailing: trailing,
    onPressed: onPressed,
    items: subItems,
    anchor: hasSubmenu ? _submenuAnchor : null,
    constraints: const BoxConstraints(minWidth: _menuMinWidth),
    child: label,
  );
}

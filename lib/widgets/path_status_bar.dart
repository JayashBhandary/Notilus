import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/browser_provider.dart';
import '../theme.dart';

/// Finder-style compact status bar at the bottom of the window.
/// Left side: tiny path chain ("MacOS › Users › jayash › Desktop").
/// Right side: item count + selection summary.
class PathStatusBar extends StatelessWidget {
  const PathStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserProvider>();
    final palette = AppColors.of(context);
    final path = browser.currentPath;
    final parts = path.isEmpty ? <String>[] : p.split(path);
    final count = browser.entries.length;
    final selected = browser.selectedPaths.length;

    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: palette.headerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: _crumbs(browser, parts, palette),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _itemSummary(count, selected),
            style: TextStyle(
              fontSize: 11,
              color: palette.subtleText,
            ),
          ),
        ],
      ),
    );
  }

  String _itemSummary(int total, int selected) {
    if (selected == 0) {
      return total == 1 ? '1 item' : '$total items';
    }
    return '$selected of $total selected';
  }

  List<Widget> _crumbs(
    BrowserProvider browser,
    List<String> parts,
    AppPalette palette,
  ) {
    final out = <Widget>[];
    String acc = '';
    for (var i = 0; i < parts.length; i++) {
      acc = i == 0 ? parts[i] : p.join(acc, parts[i]);
      final target = acc;
      final segment = parts[i].isEmpty ? '/' : parts[i];
      out.add(
        _MiniCrumb(
          icon: i == 0
              ? CupertinoIcons.device_laptop
              : CupertinoIcons.folder_fill,
          label: segment,
          onTap: () => browser.navigateTo(target),
          palette: palette,
        ),
      );
      if (i < parts.length - 1) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(
            CupertinoIcons.chevron_right,
            size: 9,
            color: palette.subtleText,
          ),
        ));
      }
    }
    return out;
  }
}

class _MiniCrumb extends StatefulWidget {
  const _MiniCrumb({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.palette,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final AppPalette palette;

  @override
  State<_MiniCrumb> createState() => _MiniCrumbState();
}

class _MiniCrumbState extends State<_MiniCrumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 11,
                color: widget.palette.subtleText,
              ),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  color: _hover
                      ? widget.palette.text
                      : widget.palette.subtleText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
